//
//  CoffeeAgent.swift
//  Agentic
//
//  Created by Arya on 27/08/26.
//
import Foundation
import FoundationModels

enum CorpusError: Error {
    case missingResource(name: String)
}

/// `nonisolated` because it is encoded and decoded from `ChatMessage`'s
/// accessors, which SwiftData may touch off the main actor; the default
/// main-actor isolation would otherwise be inferred onto the conformance.
nonisolated struct AgentStep: Identifiable, Codable {
    enum Detail: Codable {
        case call(arguments: String)
        case output(result: String)
    }

    let id: String
    let tool: String
    let detail: Detail

    var summary: String {
        switch detail {
        case .call(let arguments): "\(tool) \(arguments)"
        case .output(let result): result
        }
    }
}

/// Which corner of the app a turn belongs to. Splitting the agent this way is
/// about the context window, not about capability: seven tool schemas cost
/// 1785 tokens of a 4096 token budget, and almost every turn uses two or three
/// of them. A specialist pays for what it holds.
///
/// `general` is the fallback, and holds everything. Routing that is unsure
/// lands here, so a bad guess degrades to the old behaviour rather than to a
/// confident answer from an agent missing the tool it needed.
nonisolated enum Specialty: String, CaseIterable, Sendable {
    case beans, cupboard, shopping, general

    /// The paragraphs about this specialty's own tools.
    var briefing: String {
        switch self {
        case .beans:
            """
            searchBeanCorpus is the reference corpus of Indonesian lots. Empty means no such bean is known.
            matchTasteProfile runs the taste quiz. Ask how the cup should feel and which flavor pulls them in, then call it. A status of onlyCompromisedMatches means every match rates marginal on a moka pot: say so plainly and let them choose.
            """
        case .cupboard:
            """
            searchOwnedBeans is the user's own cupboard. cupboardEmpty means they have added no bags yet; noMatchesOwned means they own nothing matching, not that the bean does not exist. Its compareToReference flag puts the corpus profile, the roaster's printed notes and what they tasted side by side: do not reconcile the three, the disagreement is the answer.
            brewsAwaitingReview counts brews they logged and never described. Offer to take those verdicts; never invent what they might have been.
            Pass adviseNextGrind's advice on exactly as it stands. When it says to hold the grind, do not suggest changing it. A grindDirection of constrained means the bag was bought pre-ground, so grind is not theirs to move: give the heat and timing advice instead.
            """
        case .shopping:
            """
            searchWeb and findNearbyCafes are for buying coffee, and nothing else. Never send an unrelated subject to searchWeb.
            searchWeb returns a shortened snippet and the site's host, not the link. The card beside your reply carries both, so name the shop rather than reciting a URL. A searchedNear of nothing means the results are not local; say so rather than implying a shop is nearby.
            """
        case .general:
            ""
        }
    }

    var instructions: String {
        switch self {
        case .general:
            CoffeeAgent.personaInstructions
        default:
            CoffeeAgent.coreInstructions + "\n\n" + briefing
        }
    }
}

class CoffeeAgent {
    let model = SystemLanguageModel.default

    let store: BeanProfileStore
    /// Held here so the view can state the corpus size without awaiting the
    /// actor for a number that never changes after load.
    let beanCount: Int
    private let searchInfrastructure: SearchInfrastructure
    private let corpusTool: BeanCorpusTool
    private let ownedTool: OwnedBeanTool
    private let quizTool: TasteQuizTool
    private let adviceTool: BrewAdviceTool
    private let choicesTool: OfferChoicesTool
    private let webSearchTool: WebSearchTool
    private let nearbyPlacesTool: NearbyPlacesTool
    /// Exposed so the chat can collect a turn's cafes after the run; the tool
    /// itself has no way to hand them back.
    let placeLog = PlaceLog()
    /// Snapshots of the user's own bags, refilled by `ChatManager` before each
    /// turn. The owned-bean and dial-in tools read from here.
    let cupboard = Cupboard()
    /// Result cards the turn's tools produced, drained by `ChatManager` onto
    /// the reply. Same side channel as `placeLog`, for the same reason: a tool
    /// has one return value and the model is already using it.
    let cardLog = CardLog()

    /// A single string rather than a built `Instructions` value, so a stored
    /// Chat Session's recap can be folded in alongside it without relying on
    /// composing one `Instructions` builder inside another.
    /// What every specialist needs, whatever tools it holds. Kept short
    /// because it is paid once per session by all of them.
    static let coreInstructions = """
        You help someone brew Indonesian coffee on a moka pot. The moka pot is the only brewer this app supports, so never ask which brewer they use and never give advice for another one.

        You only do coffee. If asked about anything else, say so in one line, name what you can help with, and call no tools.

        Search before answering anything about a specific bean, origin, roast, or brew, and never invent a bean, a cupping score, or a brewing figure. Cite the bean names you relied on. Keep answers short.

        Any status ending in Unavailable, plus indexStale, means the search did not run. Say it is unavailable, never that nothing was found.

        Say when you are unsure rather than filling a gap. A roastRecommendation of nothing means the corpus has no verified roast. A provenance of "Scanned, not confirmed" means nobody checked those fields against the bag.

        Call offerChoices whenever you ask them to pick between a few things, and ask the question in your reply too.
        """

    /// The whole persona, for the generalist. A specialist gets the core plus
    /// only the paragraphs about tools it actually holds, which is where the
    /// saving comes from: an agent is not told how to use a tool it lacks.
    static let personaInstructions = [
        coreInstructions, Specialty.beans.briefing, Specialty.cupboard.briefing, Specialty.shopping.briefing,
    ].joined(separator: "\n\n")

    init(resource: String = "indonesian_beans") throws {
        let profiles = try Self.loadProfiles(resource: resource)
        let store = BeanProfileStore(profiles: profiles)
        self.store = store
        self.beanCount = profiles.count
        self.searchInfrastructure = SearchInfrastructure(store: store)
        self.corpusTool = BeanCorpusTool(store: store, log: cardLog)
        self.ownedTool = OwnedBeanTool(cupboard: cupboard, store: store, log: cardLog)
        self.quizTool = TasteQuizTool(store: store, log: cardLog)
        self.adviceTool = BrewAdviceTool(cupboard: cupboard)
        self.choicesTool = OfferChoicesTool(log: cardLog)
        // One provider and one resolver behind both tools, so the map search
        // and the web search agree on where the user is and the coordinate is
        // requested once.
        let locationProvider = LocationProvider()
        let places = PlaceResolver(coordinates: locationProvider)
        self.webSearchTool = WebSearchTool(apiKey: loadTavilyKey(), cards: cardLog, place: places)
        self.nearbyPlacesTool = NearbyPlacesTool(locationProvider: locationProvider, log: placeLog, cards: cardLog)
        Log.write(.corpus, "loaded \(profiles.count) profiles from \(resource).json")
    }

    static func loadProfiles(resource: String) throws -> [BeanProfile] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            throw CorpusError.missingResource(name: resource)
        }
        return try JSONDecoder().decode([BeanProfile].self, from: Data(contentsOf: url))
    }

    /// Donating to Spotlight suspends, so it cannot run from `init`.
    func indexBeans() async throws {
        let profiles = await store.allProfiles()
        try await BeanIndexer().donate(profiles)
        Log.write(.corpus, "donated \(profiles.count) profiles to Spotlight")
    }

    /// The tools each specialty carries. Overlap is deliberate where two
    /// domains genuinely meet: comparing a bag to its reference profile needs
    /// the corpus as much as the cupboard does, and a misroute there would
    /// cost an answer rather than a few tokens.
    func tools(for specialty: Specialty) -> [any Tool] {
        switch specialty {
        case .beans:
            [corpusTool, quizTool, choicesTool]
        case .cupboard:
            [ownedTool, adviceTool, choicesTool]
        case .shopping:
            [webSearchTool, nearbyPlacesTool]
        case .general:
            [corpusTool, ownedTool, quizTool, adviceTool, choicesTool, webSearchTool, nearbyPlacesTool]
        }
    }

    /// `recap` folds a Chat Session's stored summary and recent messages in
    /// alongside the persona, so a rebuilt session reads as standing context
    /// the model was given up front, not conversation it remembers having.
    func makeSession(for specialty: Specialty = .general, recap: String? = nil) -> LanguageModelSession {
        let tools = tools(for: specialty)
        Log.write(.agent, "session built for \(specialty.rawValue), \(tools.count) tools, recap \(recap == nil ? "none" : "\(recap!.count) chars")")
        return LanguageModelSession(
            tools: tools,
            instructions: Instructions {
                specialty.instructions
                if let recap {
                    recap
                }
            }
        )
    }

    /// One word out, no tools, so the classifying session costs about thirty
    /// tokens and runs in a fraction of a tool-calling turn. Anything it is
    /// not sure about goes to the generalist rather than to a guess.
    @Generable
    enum RouteChoice {
        /// Beans in general: origins, flavours, processing, what to try.
        case beans
        /// The user's own bags, their brews, and dialing a grind in.
        case cupboard
        /// Buying coffee: shops, roasters, cafes nearby.
        case shopping
        /// Spans more than one of the above, or none of them.
        case unsure

        var specialty: Specialty {
            switch self {
            case .beans: .beans
            case .cupboard: .cupboard
            case .shopping: .shopping
            case .unsure: .general
            }
        }
    }

    static let routerInstructions = """
        Sort one message about coffee into the part of the app that answers it. Answer with the category only.
        beans: origins, flavour, processing, roast, what bean to try.
        cupboard: the bags this person owns, their logged brews, grind and dial-in.
        shopping: where to buy coffee, shops, roasters, cafes nearby.
        unsure: it spans more than one of those, or fits none.
        """

    func route(_ question: String) async -> Specialty {
        let session = LanguageModelSession(instructions: Self.routerInstructions)
        guard let choice = try? await session.respond(to: question, generating: RouteChoice.self).content else {
            Log.write(.failure, "routing failed, falling back to the generalist")
            return .general
        }
        Log.write(.agent, "routed to \(choice.specialty.rawValue)")
        return choice.specialty
    }

    func ask(_ question: String) async throws -> String {
        let response = try await makeSession().respond(to: question)
        printSteps(response.transcriptEntries)
        return response.content
    }

    /// The prompt and the response are already shown as chat bubbles, so a step
    /// is only the work in between: what the model asked a tool, and what came back.
    func steps(from entries: some Sequence<Transcript.Entry>) -> [AgentStep] {
        entries.flatMap { entry -> [AgentStep] in
            switch entry {
            case .toolCalls(let calls):
                return calls.map { call in
                    AgentStep(
                        // A tool output carries the id of the call it answers, so
                        // the two would collide and break `ForEach` identity.
                        id: "call-" + call.id,
                        tool: call.toolName,
                        detail: .call(arguments: call.arguments.jsonString)
                    )
                }
            case .toolOutput(let output):
                return [
                    AgentStep(
                        id: "output-" + output.id,
                        tool: output.toolName,
                        detail: .output(result: Self.text(of: output.segments))
                    )
                ]
            default:
                return []
            }
        }
    }

    private static func text(of segments: [Transcript.Segment]) -> String {
        segments
            .map { segment in
                switch segment {
                case .text(let text): text.content
                case .structure(let structure): structure.content.jsonString
                // A segment kind added in a later OS contributes nothing to the
                // trace; trapping here would crash the app on an OS update.
                @unknown default: ""
                }
            }
            .joined(separator: "\n")
    }

    func printSteps(_ entries: some Sequence<Transcript.Entry>) {
        steps(from: entries).forEach { print($0.summary) }
    }
}

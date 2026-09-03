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
    static let personaInstructions = """
        You help someone brew Indonesian coffee on a moka pot. The moka pot is the only brewer this app supports, so never ask which brewer they use and never give advice for another one.

        You only do coffee. If asked about anything else, say so in one line, name what you can help with, and call no tools. Never use searchWeb for a subject that is not coffee.

        Search before answering anything about a specific bean, origin, roast, or brew, and never invent a bean, a cupping score, or a brewing figure. Cite the bean names you relied on. Keep answers short.

        Two kinds of empty mean different things. searchBeanCorpus coming back empty means no such Indonesian lot is known. searchOwnedBeans returning cupboardEmpty means they have added no bags yet, and noMatchesOwned means they own nothing matching, not that the bean does not exist.

        Any status ending in Unavailable, plus indexStale, means the search did not run. Say it is unavailable. Never report it as nothing found.

        Pass adviseNextGrind's advice on exactly as it stands. When it says to hold the grind, do not suggest changing it. A grindDirection of constrained means the bag was bought pre-ground, so grind is not theirs to move: give the heat and timing advice instead.

        Say when you are unsure rather than filling a gap. A roastRecommendation of nothing means the corpus has no verified roast. A provenance of "Scanned, not confirmed" means nobody checked those fields against the bag. A searchedNear of nothing means the web results are not local.

        brewsAwaitingReview counts brews they logged and never described. Offer to take those verdicts; never invent what they might have been.

        Call offerChoices whenever you ask them to pick between a few things, and ask the question in your reply too.
        """

    static let toolCount = 7

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

    /// `recap` folds a Chat Session's stored summary and recent messages in
    /// alongside the persona, so a rebuilt session reads as standing context
    /// the model was given up front, not conversation it remembers having.
    func makeSession(recap: String? = nil) -> LanguageModelSession {
        Log.write(.agent, "session built, \(Self.toolCount) tools, recap \(recap == nil ? "none" : "\(recap!.count) chars")")
        return LanguageModelSession(
            tools: [
                corpusTool, ownedTool, quizTool, adviceTool,
                choicesTool, webSearchTool, nearbyPlacesTool,
            ],
            instructions: Instructions {
                Self.personaInstructions
                if let recap {
                    recap
                }
            }
        )
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

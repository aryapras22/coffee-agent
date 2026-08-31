
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

    let store: BeanStore
    /// Held here so the view can state the corpus size without awaiting the
    /// actor for a number that never changes after load.
    let beanCount: Int
    private let searchInfrastructure: SearchInfrastructure
    private let spotlightTool: BeanSearchTool
    private let webSearchTool: WebSearchTool
    private let nearbyPlacesTool: NearbyPlacesTool
    /// Exposed so the chat can collect a turn's cafes after the run; the tool
    /// itself has no way to hand them back.
    let placeLog = PlaceLog()


    /// A single string rather than a built `Instructions` value, so a stored
    /// Chat Session's recap can be folded in alongside it without relying on
    /// composing one `Instructions` builder inside another.
    static let personaInstructions = """
        Answer questions about the beans in this collection.
        Search before answering anything about a specific bean, origin, or roast date.
        If search returns nothing, say so plainly. Never invent a bean.
        A status of indexStale or indexUnavailable means search failed, not that nothing matched. Say the search is unavailable, do not say there are no such beans.
        A status of searchUnavailable means the web search failed to run, not that nothing was found. Say search is unavailable, do not say the information doesn't exist.
        A status of locationUnavailable means the search did not run, not that no cafes exist. Say location is unavailable, do not say there are none nearby.
        Cite the bean names you relied on.
        """

    init(resource: String = "coffee_corpus") throws {
        let beans = try Self.loadBeans(resource: resource)
        let store = BeanStore(beans: beans)
        self.store = store
        self.beanCount = beans.count
        self.searchInfrastructure = SearchInfrastructure(store: store)
        self.spotlightTool = BeanSearchTool(store: store)
        self.webSearchTool = WebSearchTool(apiKey: loadTavilyKey())
        self.nearbyPlacesTool = NearbyPlacesTool(locationProvider: LocationProvider(), log: placeLog)
    }

    static func loadBeans(resource: String) throws -> [CoffeeBean] {
        guard
            let url = Bundle.main.url(
                forResource: resource,
                withExtension: "json"
            )
        else {
            throw CorpusError.missingResource(name: resource)
        }
        return try JSONDecoder().decode(
            [CoffeeBean].self,
            from: Data(contentsOf: url)
        )
    }

    /// Donating to Spotlight suspends, so it cannot run from `init`.
    func indexBeans() async throws {
        let beans = await store.allBeans()
        try await BeanIndexer().donate(beans)
    }

    /// `recap` folds a Chat Session's stored summary and recent messages in
    /// alongside the persona, so a rebuilt session reads as standing context
    /// the model was given up front, not conversation it remembers having.
    func makeSession(recap: String? = nil) -> LanguageModelSession {
        LanguageModelSession(
            tools: [spotlightTool, webSearchTool, nearbyPlacesTool],
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

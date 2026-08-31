//
//  CoffeeAgent.swift
//  Agentic
//
//  Created by Arya on 26/08/26.
//

import Foundation
import FoundationModels

let sampleBeans: [BeanSummary] = [
    BeanSummary(
        name: "Gayo Honey",
        origin: "Aceh, Indonesia",
        roastLevel: "Medium Light"
    ),
    BeanSummary(
        name: "Yirgacheffe",
        origin: "Sidamo, Ethiopia",
        roastLevel: "Light"
    ),
    BeanSummary(
        name: "Toraja Sapan",
        origin: "Sulawesi, Indonesia",
        roastLevel: "Medium"
    ),
    BeanSummary(
        name: "Supremo",
        origin: "Huila, Colombia",
        roastLevel: "Medium Dark"
    ),
    BeanSummary(
        name: "Antigua",
        origin: "Guatemala",
        roastLevel: "Dark"
    ),
]

struct BeanCatalog {

    var isReachable: Bool { sampleBeans.isEmpty }

    func search(_ query: String) -> [BeanSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        return sampleBeans.filter { bean in
            let haystack = "\(bean.name) \(bean.origin) \(bean.roastLevel)"
            return haystack.lowercased().contains(needle.lowercased())
        }
    }

    func notes(for beanName: String) -> String? {
        let needle = beanName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }

        return sampleBeans.first { bean in
            bean.name.lowercased().contains(needle.lowercased())
        }?.roastLevel
    }
}

struct InventoryClient {
    func units(for beanName: String) async throws -> Int {

        return Int.random(in: 0...10)
    }
}

@Generable
enum SearchStatus {
    case matchesFound
    case onMatchesInCatalog
    case catalogUnavailable
}

@Generable
struct BeanSummary {
    var name: String
    var origin: String
    var roastLevel: String
}

@Generable
struct SearchOutcome {
    var status: SearchStatus
    var beans: [BeanSummary]
}

@Generable
enum StockStatus {
    case inStock
    case outOfStock
}

@Generable
struct StockOutcome {
    var status: StockStatus
    var unitAvailable: Int
}

nonisolated let transientCodes: Set<URLError.Code> = [
    .timedOut, .networkConnectionLost, .notConnectedToInternet,
]

enum StockToolError: Error {
    case unreachable(underlying: Error?)
}

struct CheckStockTool: Tool {
    let name = "checkStock"
    let description = "Checks whether a named bean is currently in stock."

    let inventory: InventoryClient = InventoryClient()

    @Generable
    struct Arguments {
        @Guide(description: "Exact bean name as returned by searchBeans")
        var beanName: String
    }

    func call(arguments: Arguments) async throws -> StockOutcome {
        var lastError: Error?

        for attempt in 1...3 {
            do {
                let units = try await inventory.units(for: arguments.beanName)
                return StockOutcome(
                    status: units > 0 ? .inStock : .outOfStock,
                    unitAvailable: units
                )
            } catch let error as URLError
                where transientCodes.contains(error.code)
            {
                lastError = error

                let base = 0.2
                let delay = min(
                    pow(2.0, Double(attempt)) * base
                        + Double.random(in: 0...base),
                    4.0
                )
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw StockToolError.unreachable(underlying: lastError)
    }
}

enum AgentError: Error {
    case exhausted(turns: Int)
}

enum AgentOutcome: Equatable {
    case answer(String)
    case gaveUp(turns: Int)
    case generationFailed(String)
    case failed(String)
}

extension CoffeeAgent {
    static func outcome(for error: Error) -> AgentOutcome {
        if case .exhausted(let turns)? = error as? AgentError {
            return .gaveUp(turns: turns)
        }
        if let generation = error as? LanguageModelSession.GenerationError {
            return .generationFailed(generation.localizedDescription)
        }
        return .failed(error.localizedDescription)
    }
}

enum AgentSignal: Error {
    case finished(answer: String)
}

struct FinishTool: Tool {
    let name = "finish"
    let description =
        "Call this once you have a final recommendation. Do not call any other tool afterwards."

    @Generable
    struct Arguments {
        @Guide(
            description: "The final recommendation, in two or three sentences"
        )
        var answer: String
    }

    func call(arguments: Arguments) async throws -> String {
        // Throwing is the documented way to break a tool-calling loop.
        throw AgentSignal.finished(answer: arguments.answer)
    }
}

struct CallSignature: Hashable {
    let tool: String
    let arguments: String
}

final class LoopGuard {
    private var seen: [CallSignature: Int] = [:]
    private let limit = 2

    func record(tool: String, arguments: String) -> Bool {
        let sig = CallSignature(tool: tool, arguments: arguments)
        print("\(sig.tool) \(sig.arguments)")
        print("seen: \(seen)")
        seen[sig, default: 0] += 1
        return seen[sig, default: 0] > limit
    }
}

class CoffeeAgentLegacy {
    let model = SystemLanguageModel.default

    func checkAvailability() {
        switch model.availability {
        case .available:
            print("System is available")
        case .unavailable:
            print("System is unavailable")
        }
    }

    let instructions = Instructions {
        "You recommend coffee beans from the local catalog."
        "Every tool returns a status field. Read it before deciding what to do next."
        "matchesFound or inStock: use the data and continue."
        "noMatchesInCatalog or outOfStock: this is a correct, final answer. Report it plainly. Do not repeat the same query."
        "catalogUnavailable: the tool could not run. Try one different query, then tell the person the catalog is unavailable."
        "Never claim a bean exists unless a tool returned it."
    }

    func makeSession() -> LanguageModelSession {
        LanguageModelSession(
            tools: [
                SearchBeansTool(),
                CheckStockTool(),
                FinishTool(),
            ],
            instructions: instructions
        )
    }

    func validate(_ content: String, in session: LanguageModelSession)
        -> String?
    {

        let calledATool = session.transcript.contains { entry in
            if case .toolCalls = entry { return true }
            return false
        }

        if !calledATool {
            return
                "You answered without consulting the catalog. Use searchBeans first."
        }

        // Genuinely vacuous output.
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
                "Your last response was empty. Summarize what the tools returned."
        }

        // Deliberately absent: any check on whether matches were found.
        // "No bean in the catalog matches that" is a finished answer.
        return nil
    }

    func steps(from transcript: Transcript) -> [String] {
        transcript.compactMap { entry in
            switch entry {
            case .prompt(let p):
                return "Prompt: \(p)"
            case .toolCalls(let t):
                return "Tool: \(t)"
            case .toolOutput(let to):
                return "Tool Output: \(to)"
            case .response(let r):
                return "Response: \(r)"
            default:
                return nil
            }
        }
    }

    func printTranscript(_ transcript: Transcript) {
        steps(from: transcript).forEach { print($0) }
    }

    func recentToolCalls(in transcript: Transcript) -> [(
        tool: String, arguments: String
    )] {
        var calls: [Transcript.ToolCall] = []
        for entry in transcript {
            if case .toolCalls(let group) = entry {
                calls.append(contentsOf: group)
            }
        }

        return calls.map { ($0.toolName, String(describing: $0.arguments)) }
    }

    func giveUp(partial: [String], reason: String) -> String {
        var lines = ["I could not finish that request"]

        if !partial.isEmpty {
            lines.append("What I did find: " + partial.joined(separator: "; "))
        }

        lines.append("Why: " + reason)

        lines.append(
            "Try narrowing to one origin, or retry once the catalog is reachable"
        )

        return lines.joined(separator: "\n")
    }

    func recommed(
        goal: String,
        maxTurns: Int = 4,
        onSteps: (([String]) -> Void)? = nil
    ) async throws -> String {
        var session = makeSession()
        defer {
            let recorded = steps(from: session.transcript)
            recorded.forEach { print($0) }
            onSteps?(recorded)
        }
        var correction: String?

        let loopGuard = LoopGuard()

        for _ in 1...maxTurns {
            let prompt =
                correction.map {
                    goal + "\n\nNote on your previous attempt: " + $0
                } ?? goal

            do {
                let response = try await session.respond(to: prompt)

                for call in recentToolCalls(in: session.transcript) {
                    if loopGuard.record(
                        tool: call.tool,
                        arguments: call.arguments
                    ) {
                        return giveUp(
                            partial: [],
                            reason: "Repeated the same " + call.tool
                                + " call without new results."
                        )
                    }
                }

                if let issue = validate(response.content, in: session) {
                    correction = issue
                    continue
                }

                return response.content
            } catch AgentSignal.finished(let answer) {
                return answer
            } catch let error as LanguageModelSession.ToolCallError {
                if let signal = error.underlyingError as? AgentSignal,
                    case .finished(let answer) = signal
                {
                    return answer
                }
                correction =
                    "The " + error.tool.name
                    + " tool failed. Try a different approach."
            } catch LanguageModelSession.GenerationError
                .exceededContextWindowSize
            {
                session = makeSession()
                correction = "Context was reset. Restate your recommendation."
            }
        }

        throw AgentError.exhausted(turns: maxTurns)
    }

    func request(req: String) async throws {
        let session = LanguageModelSession(
            tools: [SearchBeansTool(), CheckStockTool(), FinishTool()],
            instructions: instructions
        )
        do {
            let _ = try await session.respond(to: req)
        } catch let error as LanguageModelSession.ToolCallError {
            print("Tool", error.tool.name, "failed", error.underlyingError)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {

        } catch {
            print("Other Error: ", error)
        }

        printTranscript(session.transcript)
    }

}

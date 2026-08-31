////
////  ContentView.swift
////  Agentic
////
////  Created by Arya on 24/08/26.
////
//
//import Foundation
//import SwiftUI
//
//struct AskResult: Identifiable {
//    let id = UUID()
//    let question: String
//    let outcome: AgentOutcome
//    let steps: [String]
//}
//
//struct ContentView: View {
//
//    let questions = [
//        "What is the ideal water temperature?",
//        // Single tool call each.
//        "can you gave me gayo coffee?",
//        "anything from ethiopia?",
//        "i want a dark roast",
//        "do you have blueberry beans?",
//
//        // Need three or more calls to one tool, each with different arguments.
//        "which of your indonesian beans are in stock?",
//        "compare stock for gayo honey, yirgacheffe, and supremo",
//        "do you have anything from indonesia, ethiopia, or colombia?",
//        "is the lightest roast or the darkest roast in stock?",
//    ]
//
//    var agent = CoffeeAgent()
//    @State private var results: [AskResult] = []
//    @State private var status: String?
//    @State private var isRunning = false
//
//    // .task fires in the Xcode canvas too, and the on-device model is not
//    // available there. Running it asserts inside FoundationModels.
//    private var isPreview: Bool {
//        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
//    }
//
//    var body: some View {
//        List {
//            if let status {
//                Text(status).foregroundStyle(.secondary)
//            }
//            ForEach(results) { result in
//                Section(result.question) {
//                    switch result.outcome {
//                    case .answer(let text):
//                        Text(text)
//                    case .gaveUp(let turns):
//                        Text("Gave up after \(turns) turns.")
//                    case .generationFailed(let reason):
//                        Text("Model could not answer: \(reason)")
//                    case .failed(let reason):
//                        Text("Failed: \(reason)")
//                    }
//
//                    DisclosureGroup("\(result.steps.count) steps") {
//                        ForEach(Array(result.steps.enumerated()), id: \.offset) { _, step in
//                            Text(step)
//                                .font(.caption)
//                                .monospaced()
//                        }
//                    }
//                }
//            }
//            if isRunning {
//                ProgressView()
//            }
//        }
//        .task {
//            guard !isPreview else {
//                status = "Preview canvas: agent not run. Use the simulator or a device."
//                return
//            }
//
//            isRunning = true
//            defer { isRunning = false }
//
//            for question in questions {
//                var steps: [String] = []
//                let outcome: AgentOutcome
//                do {
//                    let answer = try await agent.recommed(goal: question) { steps = $0 }
//                    outcome = .answer(answer)
//                } catch {
//                    outcome = CoffeeAgent.outcome(for: error)
//                }
//                results.append(
//                    AskResult(question: question, outcome: outcome, steps: steps)
//                )
//            }
//        }
//    }
//}
////
////#Preview {
////    ContentView()
////}
////

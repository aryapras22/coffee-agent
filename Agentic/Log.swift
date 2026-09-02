//
//  Log.swift
//  Agentic
//

import Foundation

/// Console tracing for development. Every line carries a fixed-width kind tag
/// so a session reads as columns and one feature can be pulled out with grep:
///
///     [SCAN ] read 412 characters off the label
///     [TOOL ] searchBeanCorpus query="gayo" limit=3
///     [TOOL ] searchBeanCorpus matchesFound 3
///
/// Compiled out of release builds, so an instrumented interaction costs
/// nothing once shipped. The message is an autoclosure for the same reason:
/// building the string is skipped when the log is off.
nonisolated enum Log {
    enum Kind: String {
        case agent = "AGENT"
        case tool = "TOOL"
        case corpus = "CORPUS"
        case cupboard = "CUPBRD"
        case brew = "BREW"
        case scan = "SCAN"
        case quiz = "QUIZ"
        case store = "STORE"
        case ui = "UI"
        case failure = "FAIL"
    }

    static func write(_ kind: Kind, _ message: @autoclosure () -> String) {
        #if DEBUG
            print("[\(kind.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))] \(message())")
        #endif
    }
}

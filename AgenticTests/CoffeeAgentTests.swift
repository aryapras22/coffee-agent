//
//  CoffeeAgentTests.swift
//  Agentic
//

import FoundationModels
import Testing

@testable import Agentic

@MainActor
struct BeanCatalogSearchTests {
    let catalog = BeanCatalog()

    @Test(
        "searches the fields the tool description advertises",
        arguments: [
            ("Ethiopia", ["Yirgacheffe"]),
            ("Indonesia", ["Gayo Honey", "Toraja Sapan"]),
            ("Medium Dark", ["Supremo"]),
        ]
    )
    func matchesOriginAndRoastLevel(query: String, expected: [String]) {
        #expect(catalog.search(query).map(\.name) == expected)
    }

    @Test func matchingIgnoresCase() {
        #expect(catalog.search("INDONESIA").count == 2)
        #expect(catalog.search("gayo").map(\.name) == ["Gayo Honey"])
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        #expect(catalog.search("  Ethiopia \n").map(\.name) == ["Yirgacheffe"])
    }

    @Test("a blank query matches nothing rather than everything")
    func blankQueryReturnsNoBeans() {
        #expect(catalog.search("   ").isEmpty)
        #expect(catalog.search("").isEmpty)
    }

    @Test func unknownQueryReturnsNoBeans() {
        #expect(catalog.search("fruity").isEmpty)
    }
}

@MainActor
struct BeanCatalogNotesTests {
    let catalog = BeanCatalog()

    @Test("an unknown bean returns nil instead of trapping")
    func missReturnsNil() {
        #expect(catalog.notes(for: "Blue Mountain") == nil)
    }

    @Test("a name lookup does not match on origin or roast level")
    func lookupIsScopedToName() {
        #expect(catalog.search("Ethiopia").count == 1)
        #expect(catalog.notes(for: "Ethiopia") == nil)
    }

    @Test func knownBeanReturnsItsRoastLevel() {
        #expect(catalog.notes(for: "Yirgacheffe") == "Light")
    }
}

@MainActor
struct ValidateTests {
    let agent = CoffeeAgent()

    private func session(calledATool: Bool) -> LanguageModelSession {
        guard calledATool else {
            return LanguageModelSession(transcript: Transcript(entries: []))
        }
        let call = Transcript.ToolCall(
            id: "1",
            toolName: "searchBeans",
            arguments: GeneratedContent("{}")
        )
        let entries: [Transcript.Entry] = [.toolCalls(Transcript.ToolCalls([call]))]
        return LanguageModelSession(transcript: Transcript(entries: entries))
    }

    @Test("an answer given without consulting the catalog is corrected")
    func ungroundedAnswerIsRejected() {
        let issue = agent.validate("Try Yirgacheffe.", in: session(calledATool: false))
        #expect(issue != nil)
    }

    @Test func emptyAnswerIsRejected() {
        let issue = agent.validate("   \n ", in: session(calledATool: true))
        #expect(issue != nil)
    }

    @Test("a grounded, non-empty answer passes")
    func groundedAnswerIsAccepted() {
        let issue = agent.validate("Yirgacheffe is in stock.", in: session(calledATool: true))
        #expect(issue == nil)
    }

    @Test("no bean matching the request is a final answer, not an error")
    func emptyResultIsNotTreatedAsFailure() {
        let issue = agent.validate(
            "Nothing in the catalog matches that.",
            in: session(calledATool: true)
        )
        #expect(issue == nil)
    }
}

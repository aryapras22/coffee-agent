//
//  WebSearchToolTests.swift
//  Agentic
//

import Foundation
import Testing

@testable import Agentic

private struct StubFetcher: URLDataFetching {
    let statusCode: Int
    let body: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

private struct ThrowingFetcher: URLDataFetching {
    struct TransportError: Error {}

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw TransportError()
    }
}

@MainActor
struct WebSearchToolTests {
    // `Arguments` is a plain struct with two stored properties and no custom
    // initializer, so its memberwise initializer is available directly —
    // no need to round-trip through `GeneratedContent`.
    private func arguments(query: String = "roast trends", maxResults: Int = 3) -> WebSearchTool.Arguments {
        WebSearchTool.Arguments(query: query, maxResults: maxResults)
    }

    @Test("a 200 response with results maps to resultsFound")
    func resultsFound() async throws {
        let body = """
            {"results": [{"title": "A roaster's blog", "url": "https://example.com", "content": "some content"}]}
            """.data(using: .utf8)!
        let tool = WebSearchTool(apiKey: "test-key", fetcher: StubFetcher(statusCode: 200, body: body))

        let outcome = try await tool.call(arguments: arguments())

        #expect(outcome.status == .resultsFound)
        #expect(outcome.results.map(\.title) == ["A roaster's blog"])
    }

    @Test("a 200 response with an empty results array maps to noResultsFound")
    func noResultsFound() async throws {
        let body = "{\"results\": []}".data(using: .utf8)!
        let tool = WebSearchTool(apiKey: "test-key", fetcher: StubFetcher(statusCode: 200, body: body))

        let outcome = try await tool.call(arguments: arguments())

        #expect(outcome.status == .noResultsFound)
        #expect(outcome.results.isEmpty)
    }

    @Test("a non-200 response maps to searchUnavailable")
    func nonTwoHundredResponse() async throws {
        let body = "{}".data(using: .utf8)!
        let tool = WebSearchTool(apiKey: "test-key", fetcher: StubFetcher(statusCode: 500, body: body))

        let outcome = try await tool.call(arguments: arguments())

        #expect(outcome.status == .searchUnavailable)
        #expect(outcome.results.isEmpty)
    }

    @Test("a 200 response with an undecodable body maps to searchUnavailable, not empty results")
    func malformedBody() async throws {
        let body = "not json at all".data(using: .utf8)!
        let tool = WebSearchTool(apiKey: "test-key", fetcher: StubFetcher(statusCode: 200, body: body))

        let outcome = try await tool.call(arguments: arguments())

        #expect(outcome.status == .searchUnavailable)
        #expect(outcome.results.isEmpty)
    }

    @Test("a transport failure maps to searchUnavailable")
    func transportFailure() async throws {
        let tool = WebSearchTool(apiKey: "test-key", fetcher: ThrowingFetcher())

        let outcome = try await tool.call(arguments: arguments())

        #expect(outcome.status == .searchUnavailable)
        #expect(outcome.results.isEmpty)
    }

    @Test("a missing key returns searchUnavailable without a network call")
    func missingKey() async throws {
        let tool = WebSearchTool(apiKey: nil, fetcher: ThrowingFetcher())

        let outcome = try await tool.call(arguments: arguments())

        #expect(outcome.status == .searchUnavailable)
        #expect(outcome.results.isEmpty)
    }

    @Test("an empty key returns searchUnavailable without a network call")
    func emptyKey() async throws {
        let tool = WebSearchTool(apiKey: "", fetcher: ThrowingFetcher())

        let outcome = try await tool.call(arguments: arguments())

        #expect(outcome.status == .searchUnavailable)
        #expect(outcome.results.isEmpty)
    }
}

struct WebSearchLocationTests {
    private let bandung = CoarsePlace(locality: "Bandung", country: "Indonesia")

    @Test("a known place is appended so the search is biased towards it")
    func placeIsAppended() {
        #expect(WebSearchTool.localised("where to buy gayo coffee", near: bandung)
            == "where to buy gayo coffee in Bandung, Indonesia")
    }

    @Test("no location leaves the query exactly as the model wrote it")
    func noPlaceLeavesTheQueryAlone() {
        #expect(WebSearchTool.localised("where to buy gayo coffee", near: nil)
            == "where to buy gayo coffee")
    }

    @Test("a query that already names the place is not given it twice")
    func alreadyNamedPlaceIsNotRepeated() {
        #expect(WebSearchTool.localised("coffee roasters in Bandung", near: bandung)
            == "coffee roasters in Bandung")
        #expect(WebSearchTool.localised("indonesia coffee exporters", near: bandung)
            == "indonesia coffee exporters")
    }

    @Test("a place with only a country still narrows the search")
    func partialPlaceStillHelps() {
        let country = CoarsePlace(locality: nil, country: "Indonesia")
        #expect(WebSearchTool.localised("moka pot", near: country) == "moka pot in Indonesia")
    }

    @Test("a place with nothing in it is the same as no place")
    func emptyPlaceChangesNothing() {
        let nowhere = CoarsePlace(locality: nil, country: nil)
        #expect(WebSearchTool.localised("moka pot", near: nowhere) == "moka pot")
    }
}

struct WebSearchTrimmingTests {
    @Test("a short snippet is passed through untouched")
    func shortSnippetIsUnchanged() {
        #expect(WebSearchTool.condensed("Sells Gayo beans.") == "Sells Gayo beans.")
    }

    @Test("a long snippet is cut to the limit on a word boundary")
    func longSnippetIsCutCleanly() {
        let long = String(repeating: "arabica beans ", count: 40)
        let result = WebSearchTool.condensed(long)
        #expect(result.count <= WebSearchTool.snippetLimit + 1)
        #expect(result.hasSuffix("…"))

        // The kept text is a genuine prefix of the input, and the character
        // it stopped before is a space, so no word was split in half.
        let body = String(result.dropLast())
        #expect(long.hasPrefix(body))
        #expect(!body.hasSuffix(" "))
        #expect(long[long.index(long.startIndex, offsetBy: body.count)] == " ")
    }

    @Test("a single unbroken run still gets cut rather than passed through")
    func unbrokenRunIsStillCut() {
        let result = WebSearchTool.condensed(String(repeating: "x", count: 400))
        #expect(result.count == WebSearchTool.snippetLimit + 1)
    }

    @Test("the host is what the model sees, without the www")
    func hostIsExtracted() {
        #expect(WebSearchTool.host(of: "https://www.ottencoffee.co.id/beans/gayo") == "ottencoffee.co.id")
        #expect(WebSearchTool.host(of: "https://tokopedia.com/x") == "tokopedia.com")
    }

    @Test("something that is not a URL is reported as it stands rather than dropped")
    func unparsableUrlSurvives() {
        #expect(WebSearchTool.host(of: "not a url") == "not a url")
    }
}

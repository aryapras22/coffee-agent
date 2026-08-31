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

//
//  WebSearchTool.swift
//  Agentic
//
//  Created by Arya on 31/08/26.
//

import FoundationModels
import Foundation

@Generable
enum WebSearchStatus {
    case resultsFound
    case noResultsFound
    case searchUnavailable
}

@Generable
struct WebSearchHit {
    var title: String
    var url: String
    var snippet: String
}

@Generable
struct WebSearchOutcome {
    var status: WebSearchStatus
    var results: [WebSearchHit]
}

/// Narrows `URLSession` to the one call `WebSearchTool` needs, so tests can
/// substitute a stub without a real network round trip.
protocol URLDataFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLDataFetching {}

/// Checks Info.plist first — the path an `.xcconfig`-backed key takes once
/// wired in the Xcode project — then falls back to an environment variable,
/// which is enough for local development without a project-file edit.
/// Either way the literal key never appears in source.
func loadTavilyKey() -> String? {
    if let fromInfoPlist = Bundle.main.object(forInfoDictionaryKey: "TavilyAPIKey") as? String,
        !fromInfoPlist.isEmpty {
        return fromInfoPlist
    }
    return ProcessInfo.processInfo.environment["TAVILY_API_KEY"]
}

struct WebSearchTool: Tool {
    let name = "searchWeb"
    let description =
        "Searches the public internet for current information not in the local catalog."

    let apiKey: String?
    let fetcher: URLDataFetching

    init(apiKey: String?, fetcher: URLDataFetching = URLSession.shared) {
        self.apiKey = apiKey
        self.fetcher = fetcher
    }

    @Generable
    struct Arguments {
        @Guide(description: "The search query")
        var query: String

        @Guide(description: "Maximum number of results to return", .range(1...5))
        var maxResults: Int
    }

    private struct RequestBody: Encodable {
        var query: String
        var max_results: Int
        var search_depth: String = "basic"
    }

    private struct ResponseBody: Decodable {
        struct Result: Decodable {
            var title: String
            var url: String
            var content: String
        }
        var results: [Result]
    }

    func call(arguments: Arguments) async throws -> WebSearchOutcome {
        guard let apiKey, !apiKey.isEmpty else {
            return WebSearchOutcome(status: .searchUnavailable, results: [])
        }

        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(query: arguments.query, max_results: arguments.maxResults)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetcher.data(for: request)
        } catch {
            return WebSearchOutcome(status: .searchUnavailable, results: [])
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return WebSearchOutcome(status: .searchUnavailable, results: [])
        }

        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            return WebSearchOutcome(status: .searchUnavailable, results: [])
        }

        let hits = decoded.results.map { WebSearchHit(title: $0.title, url: $0.url, snippet: $0.content) }

        return WebSearchOutcome(status: hits.isEmpty ? .noResultsFound : .resultsFound, results: hits)
    }
}

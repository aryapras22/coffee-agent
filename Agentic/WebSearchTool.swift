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

/// What the model sees of a result, which is deliberately less than the user
/// does. The full snippet and the link are on the card next to the reply, so
/// spending context on them buys nothing: the model cannot follow a link, and
/// a page's first paragraph is mostly boilerplate.
@Generable
struct WebSearchHit {
    var title: String
    /// The host rather than the full URL. Enough to say who is selling, at a
    /// fraction of the tokens, and the card carries the address itself.
    var source: String
    var snippet: String
}

@Generable
struct WebSearchOutcome {
    var status: WebSearchStatus
    var results: [WebSearchHit]
    /// The town the search was biased towards, or nil when location was
    /// unavailable. The model is told to say which it was rather than imply
    /// the results are local when they are not.
    var searchedNear: String?
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
    /// Optional so the tool stays constructible without the chat around it,
    /// which is how the tests exercise it.
    let cards: CardLog?
    /// Optional for the same reason as `cards`: the tool has to stay
    /// constructible without the app around it.
    let place: PlaceResolver?

    init(
        apiKey: String?,
        fetcher: URLDataFetching = URLSession.shared,
        cards: CardLog? = nil,
        place: PlaceResolver? = nil
    ) {
        self.cards = cards
        self.place = place
        self.apiKey = apiKey
        self.fetcher = fetcher
    }

    /// A whole page summary is mostly preamble, and five of them can take a
    /// third of what is left of the context window after the instructions and
    /// the tool schemas. Cut on a word boundary so the tail is a readable
    /// clause rather than half a word.
    static let snippetLimit = 180

    static func condensed(_ snippet: String, limit: Int = snippetLimit) -> String {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }

        let cut = trimmed.prefix(limit)
        guard let lastSpace = cut.lastIndex(of: " ") else { return cut + "…" }
        return cut[..<lastSpace].trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The host alone, with the leading www dropped. Falls back to the whole
    /// string when it will not parse, because a slightly long source beats
    /// telling the model nothing about where a result came from.
    static func host(of url: String) -> String {
        guard let host = URL(string: url)?.host() else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Only the town and country go out, never a coordinate. Skipped entirely
    /// when the query already names the place, so asking about Bandung does
    /// not search for "Bandung in Bandung, Indonesia".
    static func localised(_ query: String, near place: CoarsePlace?) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let described = place?.described else { return trimmed }

        let alreadyNamed = [place?.locality, place?.country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .contains { trimmed.localizedCaseInsensitiveContains($0) }

        return alreadyNamed ? trimmed : trimmed + " in " + described
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
            return WebSearchOutcome(status: .searchUnavailable, results: [], searchedNear: nil)
        }

        let near = await place?.currentPlace()
        let query = Self.localised(arguments.query, near: near)
        Log.write(.tool, "searchWeb \"\(query)\"\(near == nil ? " with no location" : "")")

        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(query: query, max_results: arguments.maxResults)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetcher.data(for: request)
        } catch {
            return WebSearchOutcome(status: .searchUnavailable, results: [], searchedNear: near?.described)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return WebSearchOutcome(status: .searchUnavailable, results: [], searchedNear: near?.described)
        }

        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            return WebSearchOutcome(status: .searchUnavailable, results: [], searchedNear: near?.described)
        }

        let hits = decoded.results.map {
            WebSearchHit(
                title: $0.title,
                source: Self.host(of: $0.url),
                snippet: Self.condensed($0.content)
            )
        }

        // The card gets the full snippet and the real link: the trimming is
        // there to protect the model's context, not the reader's.
        await cards?.append(
            decoded.results.map {
                .seller(SellerCard(name: $0.title, detail: $0.content, url: $0.url, source: "via web search"))
            }
        )
        Log.write(
            .tool,
            "searchWeb \(hits.count) results, snippets \(decoded.results.reduce(0) { $0 + $1.content.count })"
                + " chars trimmed to \(hits.reduce(0) { $0 + $1.snippet.count })"
        )
        return WebSearchOutcome(
            status: hits.isEmpty ? .noResultsFound : .resultsFound,
            results: hits,
            searchedNear: near?.described
        )
    }
}

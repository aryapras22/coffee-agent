//
//  CoffeeTools.swift
//  Agentic
//
//  Created by Arya on 27/08/26.
//

import CoreSpotlight
import FoundationModels

@Generable
enum BeanSearchStatus {
    case matchesFound
    case noMatchesInIndex
    case indexUnavailable
    case indexStale
}

@Generable
struct BeanHit {
    var name: String
    var origin: String
    var roastLevel: String
    var flavors: String
    var pricePer100gUSD: Double?
}

@Generable
struct BeanSearchOutcome {
    var status: BeanSearchStatus
    var beans: [BeanHit]
}

struct BeanSearchTool: Tool {
    let name = "searchBeanIndex"
    let description =
        "Searches the indexed bean collection by flavor note, origin, roast level, or process."

    let store: BeanStore

    @Generable
    struct Arguments {
        @Guide(description: "Flavor note, origin, roast level, or process to search for")
        var query: String

        @Guide(description: "How many beans to return", .range(1...5))
        var limit: Int
    }

    static func spotlightQuery(for needle: String) -> String {
        let fields = ["title", "keywords", "textContent"]

        return needle
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                let escaped = token
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let clauses = fields.map { "\($0) == \"\(escaped)*\"cdw" }
                return "(" + clauses.joined(separator: " || ") + ")"
            }
            .joined(separator: " && ")
    }

    func call(arguments: Arguments) async throws -> BeanSearchOutcome {
        let needle = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return BeanSearchOutcome(status: .noMatchesInIndex, beans: [])
        }

        guard CSSearchableIndex.isIndexingAvailable() else {
            return BeanSearchOutcome(status: .indexUnavailable, beans: [])
        }

        let queryString = Self.spotlightQuery(for: needle)

        let context = CSSearchQueryContext()
        context.fetchAttributes = []

        var ids: [String] = []
        let query = CSSearchQuery(queryString: queryString, queryContext: context)
        defer { query.cancel() }

        do {
            for try await result in query.results {
                ids.append(result.item.uniqueIdentifier)
                if ids.count >= arguments.limit { break }
            }
        } catch {
            return BeanSearchOutcome(status: .indexUnavailable, beans: [])
        }

        guard !ids.isEmpty else {
            return BeanSearchOutcome(status: .noMatchesInIndex, beans: [])
        }

        let beans = await store.beans(for: ids)
        guard !beans.isEmpty else {
            return BeanSearchOutcome(status: .indexStale, beans: [])
        }

        return BeanSearchOutcome(
            status: .matchesFound,
            beans: beans.map { bean in
                BeanHit(
                    name: bean.name,
                    origin: bean.origin_countries.joined(separator: ", "),
                    roastLevel: bean.roast_level ?? "unknown",
                    flavors: bean.flavor_tags.joined(separator: ", "),
                    pricePer100gUSD: bean.price_per_100g_usd
                )
            }
        )
    }
}

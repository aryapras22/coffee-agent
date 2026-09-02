//
//  BeanCorpusTool.swift
//  Agentic
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
    var island: String
    var subregion: String
    var processing: String
    var flavors: String
    var acidity: String
    var body: String
    /// Nil where the corpus has no verified recommendation, which is every
    /// Papua lot. The model is told to say so rather than fill the gap.
    var roastRecommendation: String?
    var mokaPotSuitability: String
    var cuppingScore: Double?
    var dataSource: String
}

@Generable
struct BeanSearchOutcome {
    var status: BeanSearchStatus
    var beans: [BeanHit]
}

/// The reference corpus. An empty result here means no such Indonesian lot is
/// known, which is a different answer from `OwnedBeanTool` coming back empty.
struct BeanCorpusTool: Tool {
    let name = "searchBeanCorpus"
    let description =
        "Searches the Indonesian reference corpus by island, growing region, flavor note, processing method, or roast level. Use for beans the user does not necessarily own."

    let store: BeanProfileStore

    @Generable
    struct Arguments {
        @Guide(description: "Island, growing region, flavor note, processing method, or roast level")
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

    static func hit(for profile: BeanProfile) -> BeanHit {
        BeanHit(
            name: profile.name,
            island: profile.island.label,
            subregion: profile.subregion,
            processing: profile.processingMethod.label,
            flavors: profile.flavorNotes.map(\.label).joined(separator: ", "),
            acidity: profile.acidity.label,
            body: profile.body.label,
            roastRecommendation: profile.roastRecommendation?.label,
            mokaPotSuitability: profile.mokaPotSuitability.label,
            cuppingScore: profile.cuppingScore,
            dataSource: profile.dataSource.label
        )
    }

    func call(arguments: Arguments) async throws -> BeanSearchOutcome {
        Log.write(.tool, "searchBeanCorpus query=\"\(arguments.query)\" limit=\(arguments.limit)")
        let needle = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return BeanSearchOutcome(status: .noMatchesInIndex, beans: [])
        }

        guard CSSearchableIndex.isIndexingAvailable() else {
            return BeanSearchOutcome(status: .indexUnavailable, beans: [])
        }

        let context = CSSearchQueryContext()
        context.fetchAttributes = []

        var ids: [String] = []
        let query = CSSearchQuery(queryString: Self.spotlightQuery(for: needle), queryContext: context)
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

        let profiles = await store.profiles(for: ids)
        guard !profiles.isEmpty else {
            return BeanSearchOutcome(status: .indexStale, beans: [])
        }

        Log.write(.tool, "searchBeanCorpus matchesFound \(profiles.count): \(profiles.map(\.name).joined(separator: ", "))")
        return BeanSearchOutcome(status: .matchesFound, beans: profiles.map(Self.hit))
    }
}

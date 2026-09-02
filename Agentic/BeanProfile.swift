//
//  BeanProfile.swift
//  Agentic
//

import Foundation

/// The reference corpus: Indonesian lots the app knows about, as opposed to
/// the bags the user actually owns. `nonisolated` throughout because the store
/// that holds them is an actor, so the main-actor default isolation would put
/// every read behind a hop to the main thread.
nonisolated enum Island: String, Codable, CaseIterable, Sendable {
    case sumatra, java, sulawesi, bali, flores, papua

    var label: String {
        switch self {
        case .sumatra: "Sumatra"
        case .java: "Java"
        case .sulawesi: "Sulawesi"
        case .bali: "Bali"
        case .flores: "Flores"
        case .papua: "Papua"
        }
    }
}

nonisolated enum ProcessingMethod: String, Codable, CaseIterable, Sendable {
    case washed, natural, honey, semiWashed, wetHulled, other

    var label: String {
        switch self {
        case .washed: "Washed"
        case .natural: "Natural"
        case .honey: "Honey"
        case .semiWashed: "Semi-washed"
        case .wetHulled: "Wet-hulled"
        case .other: "Other"
        }
    }
}

nonisolated enum FlavorNote: String, Codable, CaseIterable, Sendable {
    case chocolate, earthy, floral, citrus, spice, tobacco
    case caramel, nutty, fruity, woody, herbal, cedar

    var label: String { rawValue.capitalized }
}

nonisolated enum IntensityLevel: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    var label: String { rawValue.capitalized }
}

nonisolated enum RoastLevel: String, Codable, CaseIterable, Sendable {
    case light, lightMedium, medium, mediumDark, dark

    var label: String {
        switch self {
        case .light: "Light"
        case .lightMedium: "Light-medium"
        case .medium: "Medium"
        case .mediumDark: "Medium-dark"
        case .dark: "Dark"
        }
    }

    /// Ordered so the dial-in advisor and the moka rule can ask "is this a
    /// dark roast" without spelling out every case.
    var darkness: Int {
        switch self {
        case .light: 0
        case .lightMedium: 1
        case .medium: 2
        case .mediumDark: 3
        case .dark: 4
        }
    }
}

nonisolated enum Suitability: String, Codable, Sendable {
    case excellent, good, marginal

    var label: String { rawValue.capitalized }
}

/// `coffeeReview` rather than the `cqiVerified` the architecture note called
/// for: the scored rows come from the Coffee Review corpus already in this
/// repo, not from the Coffee Quality Institute database, and labelling them
/// CQI would be a claim the data does not support.
nonisolated enum DataSource: String, Codable, Sendable {
    case coffeeReview, editorialSynthesis

    var label: String {
        switch self {
        case .coffeeReview: "Coffee Review"
        case .editorialSynthesis: "Editorial synthesis"
        }
    }
}

nonisolated struct BeanProfile: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let island: Island
    let subregion: String
    let altitudeMinMeters: Int?
    let altitudeMaxMeters: Int?
    let processingMethod: ProcessingMethod
    let variety: String?
    let flavorNotes: [FlavorNote]
    let acidity: IntensityLevel
    let body: IntensityLevel
    /// Optional, unlike the rest: Papua lots in the corpus carry no verified
    /// roast recommendation, and the architecture note requires that gap be
    /// visible rather than filled with a plausible default.
    let roastRecommendation: RoastLevel?
    let cuppingScore: Double?
    let dataSource: DataSource

    /// Derived, not stored, so the roast-and-process rule has one definition.
    /// Body carries the wet-hulled character for lots whose process the corpus
    /// never recorded, which is most of the older reviews.
    var mokaPotSuitability: Suitability {
        let heavyProcess = processingMethod == .wetHulled || processingMethod == .semiWashed
        guard let roast = roastRecommendation else {
            return heavyProcess && body == .high ? .excellent : .good
        }
        if roast.darkness >= RoastLevel.medium.darkness, heavyProcess || body == .high {
            return .excellent
        }
        if roast.darkness <= RoastLevel.lightMedium.darkness, acidity == .high {
            return .marginal
        }
        return .good
    }

    var altitudeDescription: String? {
        switch (altitudeMinMeters, altitudeMaxMeters) {
        case let (min?, max?): "\(min)-\(max)m"
        case let (min?, nil): "from \(min)m"
        case let (nil, max?): "to \(max)m"
        case (nil, nil): nil
        }
    }

    /// What Spotlight indexes and what a card reads back. Built from the
    /// structured fields so the corpus file carries no prose to keep in sync.
    var searchableText: String {
        var parts = [name, island.label, subregion, processingMethod.label]
        parts += flavorNotes.map(\.label)
        parts.append("\(acidity.label) acidity")
        parts.append("\(body.label) body")
        if let roastRecommendation { parts.append("\(roastRecommendation.label) roast") }
        parts.append("moka pot \(mokaPotSuitability.label)")
        return parts.joined(separator: ", ")
    }
}

/// Links a bag the user owns to a lot in the reference corpus, so the three
/// way comparison has a published profile to sit beside the roaster's words
/// and the user's own notes.
///
/// Deterministic on purpose. Asking the model which corpus entry a bag is
/// would produce a different link on different runs from the same label, and
/// a wrong link is worse than no link: it silently attributes someone else's
/// cupping score to this bag.
nonisolated enum BeanMatcher {

    nonisolated struct Match: Sendable {
        let profile: BeanProfile
        let score: Int
        /// The tokens that carried the match, so a card can say why the link
        /// was made rather than asserting it.
        let sharedTerms: [String]

        var reason: String { "matched on " + sharedTerms.joined(separator: ", ") }
    }

    /// Words that appear on nearly every Indonesian bag and in nearly every
    /// corpus name. Leaving them in would match every lot against every bag.
    static let ignoredTerms: Set<String> = [
        "kopi", "coffee", "arabika", "arabica", "robusta", "bean", "beans",
        "roasters", "roastery", "roasted", "roast", "single", "origin",
        "premium", "specialty", "the", "and", "of", "grade", "asli", "murni",
    ]

    static func terms(in text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(words.map(String.init).filter { $0.count > 2 && !ignoredTerms.contains($0) })
    }

    /// A shared term is worth more than a shared island, and one is required:
    /// Sumatra alone covers most of the corpus, so an island-only match would
    /// link every Sumatran bag to whichever lot happened to sort first.
    static func best(
        name: String,
        subregion: String?,
        island: Island?,
        in corpus: [BeanProfile]
    ) -> Match? {
        let needle = terms(in: name).union(terms(in: subregion ?? ""))
        guard !needle.isEmpty else { return nil }

        let scored = corpus.compactMap { profile -> Match? in
            let shared = needle.intersection(terms(in: profile.name).union(terms(in: profile.subregion)))
            guard !shared.isEmpty else { return nil }
            let islandBonus = (island != nil && island == profile.island) ? 1 : 0
            return Match(profile: profile, score: shared.count * 2 + islandBonus, sharedTerms: shared.sorted())
        }

        // Ordered fully rather than by score alone, so the same bag and the
        // same corpus always produce the same link.
        return scored.max {
            ($0.score, $0.profile.cuppingScore ?? 0, $1.profile.id)
                < ($1.score, $1.profile.cuppingScore ?? 0, $0.profile.id)
        }
    }
}

actor BeanProfileStore {
    private let byID: [String: BeanProfile]
    private let all: [BeanProfile]

    init(profiles: [BeanProfile]) {
        all = profiles
        byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func profiles(for ids: [String]) -> [BeanProfile] {
        ids.compactMap { byID[$0] }
    }

    func profile(id: String) -> BeanProfile? { byID[id] }

    func allProfiles() -> [BeanProfile] { all }
}

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

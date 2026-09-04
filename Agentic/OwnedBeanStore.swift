//
//  OwnedBeanStore.swift
//  Agentic
//

import Foundation
import SwiftData

nonisolated enum ScanConfidence: String, Codable, Sendable {
    case userEntered, scanConfirmed, scanUnverified

    var label: String {
        switch self {
        case .userEntered: "Entered by hand"
        case .scanConfirmed: "Scanned and confirmed"
        case .scanUnverified: "Scanned, not confirmed"
        }
    }
}

nonisolated enum HeatLevel: String, Codable, CaseIterable, Sendable {
    case low, mediumLow, medium, high

    var label: String {
        switch self {
        case .low: "Low"
        case .mediumLow: "Medium-low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

/// How the bag was sold. The distinction is not cosmetic: a pre-ground bag
/// takes grind off the table as a variable, so the dial-in advisor has to
/// reach for heat and pull timing instead of sending the user to a grinder
/// they cannot use. That is why this lives on `OwnedBean` and not only on
/// `BrewSession`: it is a property of the bag, true of every brew from it.
nonisolated enum GrindSize: String, Codable, CaseIterable, Sendable {
    case wholeBean, coarse, medium, fine, extraFine

    var label: String {
        switch self {
        case .wholeBean: "Whole bean"
        case .coarse: "Coarse"
        case .medium: "Medium"
        case .fine: "Fine (halus)"
        case .extraFine: "Extra fine"
        }
    }

    var isAdjustable: Bool { self == .wholeBean }
}

nonisolated enum BrewSymptom: String, Codable, CaseIterable, Sendable {
    case balanced, bitter, sour, weak, burnt, channeling, sputtering

    var label: String {
        switch self {
        case .balanced: "Balanced"
        case .bitter: "Bitter"
        case .sour: "Sour"
        case .weak: "Weak"
        case .burnt: "Burnt"
        case .channeling: "Bitter and sour together"
        case .sputtering: "Sputtering or leaking"
        }
    }
}

/// What the cup did, and nothing about how much it was liked. The symptom is
/// what `BrewAdvisor` acts on; rating, flavours and intensities live on
/// `TastingNote` so no rating is ever recorded in two places.
///
/// A `BrewSession` with no outcome is awaiting review, not lacking data: the
/// timer writes the session as soon as the brew ends and never blocks on the
/// user having an opinion yet.
nonisolated struct BrewOutcome: Codable, Sendable {
    let symptom: BrewSymptom
    let note: String?
}

/// Enums are stored as their raw strings rather than as modelled attributes,
/// matching `ChatMessage`: SwiftData persists an enum by identity, so adding a
/// case to one would otherwise be a migration.
@Model
final class OwnedBean {
    var id: UUID = UUID()
    /// Links a bag to the reference corpus so a tasting note can be read
    /// against the published profile. Nil when the scan or the user named a
    /// bean the corpus does not carry.
    var corpusReferenceId: String?
    var displayName: String = ""
    var roasterName: String?
    private var islandValue: String?
    var subregion: String?
    private var processingValue: String?
    private var roastValue: String?
    var roastDate: Date?
    var purchaseDate: Date = Date.now
    var bagWeightGrams: Int?
    var remainingGrams: Int?
    private var grindSizeValue: String = GrindSize.wholeBean.rawValue
    /// As printed. Indonesian bags grade by defect count rather than by score,
    /// so "Grade 1" is a claim about the lot, not a rating of the cup.
    var grade: String?
    /// The roaster's own words, kept verbatim. Deliberately not `FlavorNote`:
    /// a bag printing "Clean" and "Balance" is naming cupping attributes, not
    /// flavours, and forcing them into the enum would either drop them or file
    /// them under something the roaster never said.
    private var roasterNotesData: Data?
    /// Filenames only. The container directory is reassigned on reinstall, so
    /// a stored absolute path would point at nothing; `BagPhotoStore` rebuilds
    /// the URL from the Documents directory at read time.
    var bagPhotoFilename: String?
    /// A close-up of the roast date stamp, which on a real bag is the least
    /// legible field and the one most often worth re-reading after saving.
    var roastDatePhotoFilename: String?
    private var scanConfidenceValue: String = ScanConfidence.userEntered.rawValue

    @Relationship(deleteRule: .cascade, inverse: \TastingNote.bean)
    var tastingNotes: [TastingNote] = []

    @Relationship(deleteRule: .cascade, inverse: \BrewSession.bean)
    var brewSessions: [BrewSession] = []

    init(
        displayName: String,
        corpusReferenceId: String? = nil,
        roasterName: String? = nil,
        island: Island? = nil,
        subregion: String? = nil,
        processingMethod: ProcessingMethod? = nil,
        roastLevel: RoastLevel? = nil,
        roastDate: Date? = nil,
        purchaseDate: Date = .now,
        bagWeightGrams: Int? = nil,
        remainingGrams: Int? = nil,
        grindSize: GrindSize = .wholeBean,
        grade: String? = nil,
        roasterNotes: [String] = [],
        bagPhotoFilename: String? = nil,
        scanConfidence: ScanConfidence = .userEntered
    ) {
        self.displayName = displayName
        self.corpusReferenceId = corpusReferenceId
        self.roasterName = roasterName
        self.islandValue = island?.rawValue
        self.subregion = subregion
        self.processingValue = processingMethod?.rawValue
        self.roastValue = roastLevel?.rawValue
        self.roastDate = roastDate
        self.purchaseDate = purchaseDate
        self.bagWeightGrams = bagWeightGrams
        self.remainingGrams = remainingGrams ?? bagWeightGrams
        self.grindSizeValue = grindSize.rawValue
        self.grade = grade
        self.roasterNotesData = Self.encodeNotes(roasterNotes)
        self.bagPhotoFilename = bagPhotoFilename
        self.scanConfidenceValue = scanConfidence.rawValue
    }

    var island: Island? {
        get { islandValue.flatMap(Island.init(rawValue:)) }
        set { islandValue = newValue?.rawValue }
    }

    var processingMethod: ProcessingMethod? {
        get { processingValue.flatMap(ProcessingMethod.init(rawValue:)) }
        set { processingValue = newValue?.rawValue }
    }

    var roastLevel: RoastLevel? {
        get { roastValue.flatMap(RoastLevel.init(rawValue:)) }
        set { roastValue = newValue?.rawValue }
    }

    var scanConfidence: ScanConfidence {
        get { ScanConfidence(rawValue: scanConfidenceValue) ?? .userEntered }
        set { scanConfidenceValue = newValue.rawValue }
    }

    var grindSize: GrindSize {
        get { GrindSize(rawValue: grindSizeValue) ?? .wholeBean }
        set { grindSizeValue = newValue.rawValue }
    }

    var roasterNotes: [String] {
        get {
            guard let roasterNotesData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: roasterNotesData)) ?? []
        }
        set { roasterNotesData = Self.encodeNotes(newValue) }
    }

    private static func encodeNotes(_ notes: [String]) -> Data? {
        notes.isEmpty ? nil : try? JSONEncoder().encode(notes)
    }

    var daysSinceRoast: Int? {
        guard let roastDate else { return nil }
        return Calendar.current.dateComponents([.day], from: roastDate, to: .now).day
    }

    var bestRating: Int? { tastingNotes.map(\.rating).max() }
}

@Model
final class TastingNote {
    var id: UUID = UUID()
    var bean: OwnedBean?
    /// The brew this note describes, when there was one. A note can also be
    /// written about a bag on its own, which is why it is not a relationship.
    var brewSessionId: UUID?
    var date: Date = Date.now
    private var acidityValue: String = IntensityLevel.medium.rawValue
    private var bodyValue: String = IntensityLevel.medium.rawValue
    private var flavorData: Data?
    var rating: Int = 3
    var freeformNote: String?

    init(
        perceivedAcidity: IntensityLevel,
        perceivedBody: IntensityLevel,
        flavorNotes: [FlavorNote],
        rating: Int,
        brewSessionId: UUID? = nil,
        freeformNote: String? = nil,
        date: Date = .now
    ) {
        self.acidityValue = perceivedAcidity.rawValue
        self.bodyValue = perceivedBody.rawValue
        self.flavorData = Self.encode(flavorNotes)
        self.rating = rating
        self.brewSessionId = brewSessionId
        self.freeformNote = freeformNote
        self.date = date
    }

    var perceivedAcidity: IntensityLevel {
        get { IntensityLevel(rawValue: acidityValue) ?? .medium }
        set { acidityValue = newValue.rawValue }
    }

    var perceivedBody: IntensityLevel {
        get { IntensityLevel(rawValue: bodyValue) ?? .medium }
        set { bodyValue = newValue.rawValue }
    }

    /// JSON rather than modelled, for the same reason `ChatMessage` stores its
    /// trace that way: nothing queries inside the list, it is written once and
    /// read back whole.
    var flavorNotes: [FlavorNote] {
        get {
            guard let flavorData else { return [] }
            return (try? JSONDecoder().decode([FlavorNote].self, from: flavorData)) ?? []
        }
        set { flavorData = Self.encode(newValue) }
    }

    private static func encode(_ notes: [FlavorNote]) -> Data? {
        notes.isEmpty ? nil : try? JSONEncoder().encode(notes)
    }
}

@Model
final class BrewSession {
    var id: UUID = UUID()
    var bean: OwnedBean?
    var date: Date = Date.now
    var potSizeCups: Int = 3
    var grindSetting: String = ""
    var doseGrams: Double?
    var preheatedWater: Bool = true
    private var heatValue: String = HeatLevel.mediumLow.rawValue

    var timeToFirstDripSeconds: Int?
    var timeToGurgleSeconds: Int?
    var totalSeconds: Int?
    var pulledAtGurgle: Bool?

    private var outcomeSymptomValue: String?
    private var outcomeNote: String?

    init(
        bean: OwnedBean?,
        potSizeCups: Int,
        grindSetting: String,
        doseGrams: Double? = nil,
        preheatedWater: Bool = true,
        heatLevel: HeatLevel = .mediumLow,
        date: Date = .now
    ) {
        self.bean = bean
        self.potSizeCups = potSizeCups
        self.grindSetting = grindSetting
        self.doseGrams = doseGrams
        self.preheatedWater = preheatedWater
        self.heatValue = heatLevel.rawValue
        self.date = date
    }

    var heatLevel: HeatLevel {
        get { HeatLevel(rawValue: heatValue) ?? .mediumLow }
        set { heatValue = newValue.rawValue }
    }

    /// Two stored columns behind one optional value. The symptom is the
    /// presence flag, so `outcome == nil` reads as "not reviewed yet" without
    /// a second field to keep in step with it.
    var outcome: BrewOutcome? {
        get {
            guard let symptom = outcomeSymptomValue.flatMap(BrewSymptom.init(rawValue:)) else {
                return nil
            }
            return BrewOutcome(symptom: symptom, note: outcomeNote)
        }
        set {
            outcomeSymptomValue = newValue?.symptom.rawValue
            outcomeNote = newValue?.note
        }
    }

    var awaitingReview: Bool { outcome == nil }
}

/// The filters the owned-bean tool exposes, as a value so the predicate can be
/// tested without a model container.
nonisolated struct OwnedBeanQuery: Sendable {
    var flavorNote: FlavorNote?
    var island: Island?
    var maxDaysSinceRoast: Int?
    var minRating: Int?
    var neverBrewed: Bool = false
    var hasRemaining: Bool = true
}

/// A plain snapshot of an `OwnedBean`, taken on the main actor so the filter
/// and the tool can work off the model actor without touching SwiftData.
nonisolated struct OwnedBeanSnapshot: Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let roasterName: String?
    let corpusReferenceId: String?
    let island: Island?
    let subregion: String?
    let processingMethod: ProcessingMethod?
    let roastLevel: RoastLevel?
    let daysSinceRoast: Int?
    let remainingGrams: Int?
    let bagWeightGrams: Int?
    let scanConfidence: ScanConfidence
    let grindSize: GrindSize
    let grade: String?
    let roasterNotes: [String]
    let bagPhotoFilename: String?
    let roastDatePhotoFilename: String?
    let tastedFlavors: [FlavorNote]
    let bestRating: Int?
    let brewCount: Int
    /// Brews logged against this bag that nobody has said anything about yet.
    let brewsAwaitingReview: Int

    init(_ bean: OwnedBean) {
        id = bean.id
        displayName = bean.displayName
        roasterName = bean.roasterName
        corpusReferenceId = bean.corpusReferenceId
        island = bean.island
        subregion = bean.subregion
        processingMethod = bean.processingMethod
        roastLevel = bean.roastLevel
        daysSinceRoast = bean.daysSinceRoast
        remainingGrams = bean.remainingGrams
        bagWeightGrams = bean.bagWeightGrams
        scanConfidence = bean.scanConfidence
        grindSize = bean.grindSize
        grade = bean.grade
        roasterNotes = bean.roasterNotes
        bagPhotoFilename = bean.bagPhotoFilename
        roastDatePhotoFilename = bean.roastDatePhotoFilename
        tastedFlavors = Array(Set(bean.tastingNotes.flatMap(\.flavorNotes)))
        bestRating = bean.bestRating
        brewCount = bean.brewSessions.count
        brewsAwaitingReview = bean.brewSessions.count { $0.outcome == nil }
    }
}

nonisolated struct BrewSessionSnapshot: Identifiable, Sendable {
    let id: UUID
    let beanId: UUID?
    let beanName: String
    let date: Date
    let grindSetting: String
    let potSizeCups: Int
    let heatLevel: HeatLevel
    let timeToFirstDripSeconds: Int?
    let timeToGurgleSeconds: Int?
    let totalSeconds: Int?
    let outcome: BrewOutcome?

    init(_ session: BrewSession) {
        id = session.id
        beanId = session.bean?.id
        beanName = session.bean?.displayName ?? "Unnamed bean"
        date = session.date
        grindSetting = session.grindSetting
        potSizeCups = session.potSizeCups
        heatLevel = session.heatLevel
        timeToFirstDripSeconds = session.timeToFirstDripSeconds
        timeToGurgleSeconds = session.timeToGurgleSeconds
        totalSeconds = session.totalSeconds
        outcome = session.outcome
    }
}

nonisolated enum OwnedBeanSearch {
    static func matches(_ query: OwnedBeanQuery, in beans: [OwnedBeanSnapshot]) -> [OwnedBeanSnapshot] {
        beans.filter { bean in
            if query.hasRemaining, let grams = bean.remainingGrams, grams <= 0 { return false }
            if let note = query.flavorNote, !bean.tastedFlavors.contains(note) { return false }
            if let island = query.island, bean.island != island { return false }
            if let maxDays = query.maxDaysSinceRoast {
                guard let days = bean.daysSinceRoast, days <= maxDays else { return false }
            }
            if let minimum = query.minRating {
                guard let best = bean.bestRating, best >= minimum else { return false }
            }
            if query.neverBrewed, bean.brewCount > 0 { return false }
            return true
        }
    }
}

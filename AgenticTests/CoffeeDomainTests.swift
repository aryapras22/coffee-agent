//
//  CoffeeDomainTests.swift
//  AgenticTests
//

import Foundation
import Testing

@testable import Agentic

private func profile(
    id: String = "p",
    process: ProcessingMethod = .washed,
    roast: RoastLevel? = .medium,
    acidity: IntensityLevel = .medium,
    body: IntensityLevel = .medium,
    flavors: [FlavorNote] = [.chocolate],
    score: Double? = nil
) -> BeanProfile {
    BeanProfile(
        id: id,
        name: id,
        island: .sumatra,
        subregion: "Test",
        altitudeMinMeters: nil,
        altitudeMaxMeters: nil,
        processingMethod: process,
        variety: nil,
        flavorNotes: flavors,
        acidity: acidity,
        body: body,
        roastRecommendation: roast,
        cuppingScore: score,
        dataSource: .editorialSynthesis
    )
}

struct MokaSuitabilityTests {
    @Test("wet-hulled at medium-dark is the ideal case")
    func wetHulledDarkIsExcellent() {
        #expect(profile(process: .wetHulled, roast: .mediumDark).mokaPotSuitability == .excellent)
    }

    @Test("a washed light-medium lot with high acidity is the compromise case")
    func washedBrightIsMarginal() {
        #expect(profile(process: .washed, roast: .lightMedium, acidity: .high).mokaPotSuitability == .marginal)
    }

    @Test("a light roast without high acidity is not penalised")
    func lightButNotBrightIsGood() {
        #expect(profile(process: .washed, roast: .light, acidity: .low).mokaPotSuitability == .good)
    }

    @Test("body stands in for a process the corpus never recorded")
    func heavyBodyCarriesAnUnknownProcess() {
        #expect(profile(process: .other, roast: .medium, body: .high).mokaPotSuitability == .excellent)
    }

    @Test("an unverified roast falls back to process and body, not to a guess")
    func missingRoastUsesProcessAndBody() {
        #expect(profile(process: .wetHulled, roast: nil, body: .high).mokaPotSuitability == .excellent)
        #expect(profile(process: .washed, roast: nil, body: .medium).mokaPotSuitability == .good)
    }
}

struct TasteQuizTests {
    private let corpus = [
        profile(id: "bright-marginal", process: .washed, roast: .lightMedium, acidity: .high, flavors: [.citrus]),
        profile(id: "bright-ok", process: .natural, roast: .medium, acidity: .high, body: .high, flavors: [.citrus], score: 85),
        profile(id: "heavy", process: .wetHulled, roast: .mediumDark, acidity: .low, body: .high, flavors: [.earthy], score: 88),
    ]

    @Test("the moka filter splits matches instead of discarding them")
    func marginalMatchesAreReportedSeparately() {
        let result = TasteQuiz.match(QuizAnswer(feel: .brightLively, flavorPull: .citrus), in: corpus)
        #expect(result.fit.map(\.id) == ["bright-ok"])
        #expect(result.compromised.map(\.id) == ["bright-marginal"])
    }

    @Test("acidity has to match the branch, not just the flavour")
    func feelBranchNarrowsByAcidity() {
        let result = TasteQuiz.match(QuizAnswer(feel: .smoothHeavy, flavorPull: .citrus), in: corpus)
        #expect(result.isEmpty)
    }

    @Test("an unscored bean sorts below a scored one rather than above it")
    func unscoredBeansSortLast() {
        let scored = profile(id: "scored", process: .wetHulled, roast: .medium, body: .high, flavors: [.chocolate], score: 90)
        let unscored = profile(id: "unscored", process: .wetHulled, roast: .medium, body: .high, flavors: [.chocolate])
        let result = TasteQuiz.match(
            QuizAnswer(feel: .balanced, flavorPull: .chocolate),
            in: [unscored, scored]
        )
        #expect(result.fit.map(\.id) == ["scored", "unscored"])
    }
}

struct DialInTests {
    private func session(_ symptom: BrewSymptom?, grind: String = "12", daysAgo: Int = 0) -> BrewSessionSnapshot {
        let bean = OwnedBean(displayName: "Test")
        let brew = BrewSession(bean: bean, potSizeCups: 3, grindSetting: grind)
        brew.date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        brew.outcome = symptom.map { BrewOutcome(rating: 3, symptom: $0, note: nil) }
        return BrewSessionSnapshot(brew)
    }

    @Test("bitter goes coarser, weak goes finer")
    func extractionFaultsMoveTheGrind() {
        #expect(BrewAdvisor.nextGrind(from: [session(.bitter)]).direction == .coarser)
        #expect(BrewAdvisor.nextGrind(from: [session(.burnt)]).direction == .coarser)
        #expect(BrewAdvisor.nextGrind(from: [session(.weak)]).direction == .finer)
        #expect(BrewAdvisor.nextGrind(from: [session(.sour)]).direction == .finer)
    }

    @Test("channeling and sputtering hold the grind, because neither is a grind fault")
    func bedAndHardwareFaultsHoldTheGrind() {
        #expect(BrewAdvisor.nextGrind(from: [session(.channeling)]).direction == .hold)
        #expect(BrewAdvisor.nextGrind(from: [session(.sputtering)]).direction == .hold)
    }

    @Test("only the most recent rated brew decides the next move")
    func mostRecentRatedBrewWins() {
        let history = [session(.bitter, grind: "14", daysAgo: 0), session(.weak, grind: "10", daysAgo: 3)]
        let advice = BrewAdvisor.nextGrind(from: history)
        #expect(advice.direction == .coarser)
        #expect(advice.message.contains("14"))
    }

    @Test("an unrated brew is not history to act on")
    func unratedBrewsAreIgnored() {
        #expect(BrewAdvisor.nextGrind(from: [session(nil)]).direction == .unknown)
    }

    @Test("roast shifts the starting point in opposite directions")
    func startingPointFollowsRoast() {
        #expect(BrewAdvisor.startingPoint(for: .dark).contains("coarser"))
        #expect(BrewAdvisor.startingPoint(for: .light).contains("finer"))
        #expect(!BrewAdvisor.startingPoint(for: .medium).contains("coarser"))
    }

    @Test("first drip timing separates too-hot from choked")
    func firstDripVerdictSplitsTheFaults() {
        #expect(BrewAdvisor.firstDripVerdict(seconds: 25).contains("heat"))
        #expect(BrewAdvisor.firstDripVerdict(seconds: 55).contains("range"))
        #expect(BrewAdvisor.firstDripVerdict(seconds: 180).contains("choking"))
    }
}

@MainActor
struct OwnedBeanSearchTests {
    private func snapshot(
        name: String,
        roastedDaysAgo: Int? = nil,
        remaining: Int? = 200,
        flavors: [FlavorNote] = [],
        rating: Int? = nil,
        brews: Int = 0
    ) -> OwnedBeanSnapshot {
        let bean = OwnedBean(
            displayName: name,
            roastDate: roastedDaysAgo.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: .now) },
            remainingGrams: remaining
        )
        if !flavors.isEmpty || rating != nil {
            let note = TastingNote(
                perceivedAcidity: .medium,
                perceivedBody: .medium,
                flavorNotes: flavors,
                rating: rating ?? 3
            )
            bean.tastingNotes.append(note)
        }
        for _ in 0..<brews {
            bean.brewSessions.append(BrewSession(bean: bean, potSizeCups: 3, grindSetting: "12"))
        }
        return OwnedBeanSnapshot(bean)
    }

    @Test("a finished bag is excluded unless asked for")
    func emptyBagsAreHiddenByDefault() {
        let beans = [snapshot(name: "full"), snapshot(name: "empty", remaining: 0)]
        #expect(OwnedBeanSearch.matches(OwnedBeanQuery(), in: beans).map(\.displayName) == ["full"])
        #expect(OwnedBeanSearch.matches(OwnedBeanQuery(hasRemaining: false), in: beans).count == 2)
    }

    @Test("a flavour filter reads tasting notes, not the label")
    func flavorFilterUsesTastedNotes() {
        let beans = [snapshot(name: "choc", flavors: [.chocolate]), snapshot(name: "plain")]
        var query = OwnedBeanQuery()
        query.flavorNote = .chocolate
        #expect(OwnedBeanSearch.matches(query, in: beans).map(\.displayName) == ["choc"])
    }

    @Test("a bag with no roast date cannot satisfy a freshness filter")
    func missingRoastDateFailsFreshness() {
        let beans = [snapshot(name: "fresh", roastedDaysAgo: 5), snapshot(name: "undated")]
        var query = OwnedBeanQuery()
        query.maxDaysSinceRoast = 14
        #expect(OwnedBeanSearch.matches(query, in: beans).map(\.displayName) == ["fresh"])
    }

    @Test("never-brewed excludes anything with a session against it")
    func neverBrewedExcludesBrewedBags() {
        let beans = [snapshot(name: "untried"), snapshot(name: "tried", brews: 2)]
        var query = OwnedBeanQuery()
        query.neverBrewed = true
        #expect(OwnedBeanSearch.matches(query, in: beans).map(\.displayName) == ["untried"])
    }

    @Test("an unrated bag does not clear a minimum rating")
    func minimumRatingNeedsARating() {
        let beans = [snapshot(name: "loved", rating: 5), snapshot(name: "unrated")]
        var query = OwnedBeanQuery()
        query.minRating = 4
        #expect(OwnedBeanSearch.matches(query, in: beans).map(\.displayName) == ["loved"])
    }
}

struct BagScanDateTests {
    private func day(_ date: Date?) -> DateComponents? {
        date.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) }
    }

    @Test("the format the model is asked for parses")
    func isoFormatParses() {
        #expect(day(BagScanner.parseDate("2026-08-28"))?.month == 8)
        #expect(day(BagScanner.parseDate("2026-08-28"))?.day == 28)
    }

    @Test("an Indonesian month name copied off the bag still parses")
    func indonesianMonthParses() {
        let parsed = day(BagScanner.parseDate("28 Agustus 2026"))
        #expect(parsed?.year == 2026)
        #expect(parsed?.month == 8)
        #expect(parsed?.day == 28)
    }

    @Test("unreadable text yields no date rather than today's")
    func garbageYieldsNil() {
        #expect(BagScanner.parseDate("ROAST DATE") == nil)
        #expect(BagScanner.parseDate("  ") == nil)
        #expect(BagScanner.parseDate(nil) == nil)
    }
}

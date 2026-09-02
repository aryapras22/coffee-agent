//
//  CoffeeDomainTests.swift
//  AgenticTests
//

import Foundation
import Testing
import FoundationModels
import UIKit
import Vision

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
        brew.outcome = symptom.map { BrewOutcome(symptom: $0, note: nil) }
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

/// A brew with no outcome is awaiting review, not lacking data, and the two
/// have to stay distinguishable for the dial-in to know what it is missing.
@MainActor
struct BrewReviewStateTests {
    private func session(_ symptom: BrewSymptom?) -> BrewSession {
        let brew = BrewSession(bean: nil, potSizeCups: 3, grindSetting: "12")
        brew.outcome = symptom.map { BrewOutcome(symptom: $0, note: nil) }
        return brew
    }

    @Test("a finished brew starts awaiting review rather than rated")
    func aNewBrewIsAwaitingReview() {
        #expect(session(nil).awaitingReview)
        #expect(session(nil).outcome == nil)
    }

    @Test("the symptom is the presence flag, so a reviewed brew is never nil")
    func aReviewedBrewIsNotAwaiting() {
        let reviewed = session(.bitter)
        #expect(!reviewed.awaitingReview)
        #expect(reviewed.outcome?.symptom == .bitter)
    }

    @Test("a note without a verdict is not a review")
    func noteAloneDoesNotCountAsReviewed() {
        let brew = session(nil)
        brew.outcome = nil
        #expect(brew.awaitingReview)
    }

    @Test("unreviewed brews are invisible to the dial-in, which is why they are counted")
    func unreviewedBrewsCarryNoAdvice() {
        let bean = OwnedBean(displayName: "Test")
        let brews = [session(nil), session(nil)]
        brews.forEach { $0.bean = bean; bean.brewSessions.append($0) }

        let snapshots = brews.map(BrewSessionSnapshot.init)
        #expect(BrewAdvisor.nextGrind(from: snapshots).direction == .unknown)
        #expect(OwnedBeanSnapshot(bean).brewsAwaitingReview == 2)
    }

    @Test("a rating lives on the tasting note, never on the outcome")
    func ratingIsNotDuplicated() {
        let bean = OwnedBean(displayName: "Test")
        let brew = session(.balanced)
        brew.bean = bean
        bean.brewSessions.append(brew)

        let note = TastingNote(
            perceivedAcidity: .low,
            perceivedBody: .high,
            flavorNotes: [.chocolate],
            rating: 5,
            brewSessionId: brew.id
        )
        bean.tastingNotes.append(note)

        // Traceable back to the grind and heat that produced the cup.
        #expect(note.brewSessionId == brew.id)
        #expect(OwnedBeanSnapshot(bean).bestRating == 5)
        #expect(OwnedBeanSnapshot(bean).brewsAwaitingReview == 0)
    }
}

/// Only the filename is persisted, because the container directory is
/// reassigned on reinstall and a stored absolute path would point at nothing.
struct BagPhotoStoreTests {
    private func image(_ size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor.brown.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test("a camera-sized frame is scaled to the long edge, keeping its shape")
    func longEdgeIsCapped() {
        let scaled = BagPhotoStore.downscaled(image(CGSize(width: 3213, height: 5712)))
        #expect(max(scaled.size.width, scaled.size.height) == BagPhotoStore.maxEdge)
        let ratio = scaled.size.width / scaled.size.height
        #expect(abs(ratio - 3213.0 / 5712.0) < 0.01)
    }

    @Test("an image already small enough is not enlarged")
    func smallImagesAreLeftAlone() {
        let original = image(CGSize(width: 400, height: 300))
        #expect(BagPhotoStore.downscaled(original).size == original.size)
    }

    @Test("what is stored is a bare filename, and the URL is rebuilt from it")
    func onlyTheFilenameIsStored() async throws {
        let filename = try await BagPhotoStore.save(image(CGSize(width: 2400, height: 1800)))
        defer { BagPhotoStore.delete(filename) }

        #expect(!filename.contains("/"))
        #expect(filename.hasSuffix(".jpg"))
        #expect(BagPhotoStore.image(named: filename) != nil)

        let rebuilt = try #require(BagPhotoStore.url(for: filename))
        #expect(rebuilt.lastPathComponent == filename)
        #expect(rebuilt.path().contains("Documents"))
    }

    @Test("deleting removes the file, and deleting nothing is not an error")
    func deleteIsBestEffort() async throws {
        let filename = try await BagPhotoStore.save(image(CGSize(width: 800, height: 600)))
        BagPhotoStore.delete(filename)
        #expect(BagPhotoStore.image(named: filename) == nil)

        BagPhotoStore.delete(nil)
        BagPhotoStore.delete("does-not-exist.jpg")
    }
}

struct BagScanLanguageTests {
    private func language(_ id: String) -> Locale.Language { Locale.Language(identifier: id) }

    @Test("both languages are requested, Indonesian first, because bags print both")
    func indonesianLeadsTheOrderedList() {
        let supported = [language("en-US"), language("id-ID")]
        let chosen = BagScanner.recognitionLanguages(supported: supported)
        #expect(chosen.map(\.languageCode) == [language("id").languageCode, language("en").languageCode])
    }

    @Test("an OS without the Indonesian recogniser still reads the bag in English")
    func missingIndonesianDegradesRatherThanFails() {
        let supported = [language("en-US"), language("fr-FR")]
        let chosen = BagScanner.recognitionLanguages(supported: supported)
        #expect(chosen.map(\.languageCode) == [language("en-US").languageCode])
    }

    @Test("an empty supported list still yields a recogniser rather than none")
    func emptySupportedListStillPicksEnglish() {
        #expect(BagScanner.recognitionLanguages(supported: []).count == 1)
    }

    @Test("this OS carries the Indonesian recogniser at the accurate level")
    func indonesianIsAvailableHere() {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        let codes = request.supportedRecognitionLanguages.map(\.languageCode)
        #expect(codes.contains(language("id").languageCode))
    }

    /// `.fast` covers six languages and Indonesian is not among them, so a
    /// change of recognition level would quietly drop half of a bilingual bag.
    @Test("the fast recogniser cannot read Indonesian, which is why the scan stays accurate")
    func fastLevelWouldLoseIndonesian() {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .fast
        let codes = request.supportedRecognitionLanguages.map(\.languageCode)
        #expect(!codes.contains(language("id").languageCode))
    }
}

/// Foundation Models supports 23 locales and Indonesian is not one of them,
/// so an Indonesian label has to reach it as English or not at all.
struct BagScanNormalizationTests {
    @Test("the on-device model has no Indonesian, which is what forces the pre-pass")
    func indonesianIsNotAModelLanguage() {
        let codes = SystemLanguageModel.default.supportedLanguages.map(\.languageCode)
        #expect(!codes.contains(Locale.Language(identifier: "id").languageCode))
    }

    @Test("label terms become English while place names are left alone")
    func termsAreSubstitutedAndNamesArePreserved() {
        let normalized = BagScanner.normalize("Proses: Giling Basah, Bener Meriah, Aceh")
        #expect(normalized.localizedCaseInsensitiveContains("process"))
        #expect(normalized.localizedCaseInsensitiveContains("wet hulled"))
        #expect(normalized.contains("Bener Meriah"))
        #expect(normalized.contains("Aceh"))
    }

    @Test("a longer phrase is not half-consumed by a shorter one inside it")
    func longestPhraseWins() {
        #expect(BagScanner.normalize("Berat Bersih 200 g").localizedCaseInsensitiveContains("net weight"))
        #expect(BagScanner.normalize("Tanggal Sangrai 28 Agustus 2026").localizedCaseInsensitiveContains("roast date"))
    }

    @Test("an Indonesian month becomes one the date parser accepts")
    func monthsAreTranslated() {
        let normalized = BagScanner.normalize("28 Agustus 2026")
        #expect(normalized == "28 August 2026")
        #expect(BagScanner.parseDate(normalized) != nil)
    }

    @Test("an all-English bag passes through untouched")
    func englishIsLeftAlone() {
        let english = "Single Origin, Whole Bean, Washed, Roasted 12 March 2026"
        #expect(BagScanner.normalize(english) == english)
    }
}

/// The floor the user lands on when the model refuses the text outright.
struct BagScanFallbackTests {
    private func fields(_ raw: String) -> BagScanner.Draft {
        BagScanner.deterministicFields(from: BagScanner.normalize(raw))
    }

    @Test("process, roast, date and weight come off the vocabulary without the model")
    func closedVocabularyFillsFourFields() {
        let draft = fields("""
            KOPI ARABIKA GAYO
            Proses: Giling Basah
            Sangrai: Medium Gelap
            Tanggal Sangrai: 28 Agustus 2026
            Berat Bersih 200 g
            """)

        #expect(draft.processingMethod == .wetHulled)
        #expect(draft.roastLevel == .mediumDark)
        #expect(draft.weightGrams == 200)
        #expect(draft.roastDate != nil)
        #expect(draft.scanConfidence == .scanUnverified)
    }

    @Test("a compound roast is not read as its first word")
    func compoundRoastBeatsItsParts() {
        #expect(fields("Sangrai Medium Gelap").roastLevel == .mediumDark)
        #expect(fields("Sangrai Gelap").roastLevel == .dark)
        #expect(fields("Roast: Medium").roastLevel == .medium)
    }

    @Test("semi-washed is not collapsed into washed")
    func compoundProcessBeatsItsParts() {
        #expect(fields("Proses: Semi Basah").processingMethod == .semiWashed)
        #expect(fields("Proses: Cuci").processingMethod == .washed)
    }

    @Test("a bag stating none of it yields an empty draft rather than guesses")
    func nothingStatedYieldsNothing() {
        let draft = fields("Artisan Coffee Roasters")
        #expect(draft.processingMethod == nil)
        #expect(draft.roastLevel == nil)
        #expect(draft.weightGrams == nil)
        #expect(draft.roastDate == nil)
    }
}

/// Renders a label panel the way an Indonesian bag prints one, half in each
/// language, and runs it through the real recogniser. Synthetic type is kinder
/// than a matte curved bag, so this proves the configuration reads Indonesian
/// at all, not that any given photograph will.
@MainActor
struct BagScanReadingTests {
    private func labelImage(_ lines: [String]) -> CGImage {
        let size = CGSize(width: 1000, height: 1300)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .medium),
                .foregroundColor: UIColor.black,
            ]
            for (index, line) in lines.enumerated() {
                line.draw(at: CGPoint(x: 60, y: 60 + index * 110), withAttributes: attributes)
            }
        }
        return image.cgImage!
    }

    @Test("Indonesian and English on one panel both come back")
    func bilingualPanelIsRead() async throws {
        let image = labelImage([
            "KOPI ARABIKA GAYO",
            "Bener Meriah, Aceh",
            "Proses: Giling Basah",
            "Single Origin, Whole Bean",
            "Tanggal Sangrai: 28 Agustus 2026",
            "Berat Bersih 200 g",
        ])

        let text = try await BagScanner.readText(from: image).lowercased()

        #expect(text.contains("gayo"))
        #expect(text.contains("giling"))
        #expect(text.contains("basah"))
        #expect(text.contains("agustus"))
        #expect(text.contains("single origin"))
    }

    @Test("an Indonesian panel survives the whole pipeline and reaches the confirm screen")
    func indonesianPanelYieldsAUsableDraft() async throws {
        guard SystemLanguageModel.default.availability == .available else { return }

        let image = labelImage([
            "KOPI ARABIKA GAYO",
            "Bener Meriah, Aceh",
            "Proses: Giling Basah",
            "Sangrai: Medium Gelap",
            "Tanggal Sangrai: 28 Agustus 2026",
            "Berat Bersih 200 g",
        ])

        let raw = try await BagScanner.readText(from: image)
        let draft = await BagScanner.draft(fromOCR: raw)

        // Whichever path ran, model or fallback, the user gets these four.
        #expect(draft.processingMethod == .wetHulled)
        #expect(draft.roastLevel == .mediumDark)
        #expect(draft.weightGrams == 200)
        #expect(draft.roastDate != nil)
        #expect(draft.scanConfidence == .scanUnverified)
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

    @Test("an OCR garble of a month is repaired when only one month is close")
    func garbledMonthIsRepaired() {
        let parsed = day(BagScanner.parseDate("01 AUb 2026"))
        #expect(parsed?.year == 2026)
        #expect(parsed?.month == 8)
        #expect(parsed?.day == 1)
    }

    @Test("a garble close to several months is left blank rather than guessed")
    func ambiguousMonthIsRefused() {
        // "mai" sits one character from March, May and Indonesian Mei.
        #expect(BagScanner.parseDate("01 Mai 2026") == nil)
    }

    @Test("a word that is no month at all is not forced into one")
    func distantWordIsNotAMonth() {
        #expect(BagScanner.parseDate("01 Roasted 2026") == nil)
        #expect(BagScanner.parseDate("200 Grams 2026") == nil)
    }

    @Test("unreadable text yields no date rather than today's")
    func garbageYieldsNil() {
        #expect(BagScanner.parseDate("ROAST DATE") == nil)
        #expect(BagScanner.parseDate("  ") == nil)
        #expect(BagScanner.parseDate(nil) == nil)
    }
}

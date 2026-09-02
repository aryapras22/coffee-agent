//
//  BagScanner.swift
//  Agentic
//

import CoreGraphics
import Foundation
import FoundationModels
import Vision

/// What the model pulls out of a bag label. Every field is optional because a
/// bag that omits its roast date is common, and inventing one would be worse
/// than leaving the field blank on the confirm screen.
@Generable
struct ScannedBagFields {
    @Guide(description: "The coffee's name as printed, without the roaster's company name")
    var name: String?

    @Guide(description: "The roaster or company that packed the bag")
    var roaster: String?

    @Guide(description: "Indonesian island of origin, if the label names one")
    var island: IslandArgument?

    @Guide(description: "Growing region, regency, or province as printed")
    var subregion: String?

    @Guide(description: "Processing method. Giling basah means wet-hulled.")
    var processing: ProcessingArgument?

    @Guide(description: "Roast level as printed")
    var roast: RoastArgument?

    @Guide(description: "Roast date as yyyy-MM-dd. Indonesian month names are common: Januari, Februari, Maret, April, Mei, Juni, Juli, Agustus, September, Oktober, November, Desember.")
    var roastDate: String?

    @Guide(description: "Net bag weight in grams", .range(10...5000))
    var weightGrams: Int?
}

@Generable
enum ProcessingArgument {
    case washed, natural, honey, semiWashed, wetHulled, other

    var method: ProcessingMethod {
        switch self {
        case .washed: .washed
        case .natural: .natural
        case .honey: .honey
        case .semiWashed: .semiWashed
        case .wetHulled: .wetHulled
        case .other: .other
        }
    }
}

@Generable
enum RoastArgument {
    case light, lightMedium, medium, mediumDark, dark

    var level: RoastLevel {
        switch self {
        case .light: .light
        case .lightMedium: .lightMedium
        case .medium: .medium
        case .mediumDark: .mediumDark
        case .dark: .dark
        }
    }
}

nonisolated enum BagScanError: Error, LocalizedError {
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .noTextFound: "No text could be read off that image."
        }
    }
}

nonisolated enum BagScanner {

    /// Terms an English recogniser would otherwise correct into English words.
    /// Indonesian bags print these on the panel the scan is aimed at.
    static let labelVocabulary = [
        "Kopi", "Arabika", "Robusta", "Giling", "Basah", "Sangrai", "Proses",
        "Gayo", "Aceh", "Mandheling", "Lintong", "Toraja", "Kintamani",
        "Bajawa", "Flores", "Wamena", "Preanger", "Ijen", "Bener", "Meriah",
    ]

    /// Vision has no Indonesian recogniser: asking it to detect the language
    /// makes it find `id`, log that the locale is unsupported, and fall back
    /// anyway. Indonesian is Latin script, so an English recogniser reads it
    /// fine, and the vocabulary above stops language correction from
    /// rewriting the words that matter.
    static func recognitionLanguages(supported: [Locale.Language]) -> [Locale.Language] {
        let preferred = [Locale.Language(identifier: "id"), Locale.Language(identifier: "en-US")]
        let available = preferred.filter { candidate in
            supported.contains { $0.languageCode == candidate.languageCode }
        }
        return available.isEmpty ? [Locale.Language(identifier: "en-US")] : available
    }

    /// One image at a time, deliberately. Running more than two
    /// `RecognizeTextRequest` operations concurrently can deadlock Vision, and
    /// there is no reason here to scan bags in parallel.
    static func readText(from image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = recognitionLanguages(supported: request.supportedRecognitionLanguages)
        request.customWords = labelVocabulary

        Log.write(.scan, "recognising with \(request.recognitionLanguages.map(\.maximalIdentifier).joined(separator: ", "))")

        let observations = try await request.perform(on: image)
        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.write(.failure, "OCR found no text in the image")
            throw BagScanError.noTextFound
        }
        Log.write(.scan, "read \(observations.count) lines, \(text.count) characters")
        return text
    }

    /// Guided generation straight off the OCR text, with no regex pre-pass.
    /// The confirm screen is what catches a misread, so a second extraction
    /// path would add a place for the two to disagree without removing the
    /// need to check.
    static func extract(from ocrText: String) async throws -> ScannedBagFields {
        let session = LanguageModelSession(
            instructions: """
                You are reading text scanned off an Indonesian coffee bag.
                Fill only the fields the text actually states. Leave a field empty rather than guessing.
                The text may mix Indonesian and English, and OCR may have garbled it.
                "Giling basah" is wet-hulled. "Proses" means process. "Sangrai" or "Roasted" precedes the roast date.
                """
        )
        let fields = try await session.respond(to: ocrText, generating: ScannedBagFields.self).content
        Log.write(.scan, "extracted name=\(fields.name ?? "-") roaster=\(fields.roaster ?? "-") island=\(fields.island.map { "\($0)" } ?? "-") process=\(fields.processing.map { "\($0)" } ?? "-") roast=\(fields.roast.map { "\($0)" } ?? "-") date=\(fields.roastDate ?? "-") weight=\(fields.weightGrams.map(String.init) ?? "-")")
        return fields
    }

    /// Accepts what the model returned as well as the formats a label prints,
    /// so a date it copied through verbatim still lands.
    static func parseDate(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        let formats = ["yyyy-MM-dd", "dd-MM-yyyy", "dd/MM/yyyy", "d MMMM yyyy", "d MMM yyyy", "MMMM d, yyyy"]
        let locales = [Locale(identifier: "en_US_POSIX"), Locale(identifier: "id_ID")]

        for locale in locales {
            for format in formats {
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.dateFormat = format
                if let date = formatter.date(from: text) { return date }
            }
        }
        return nil
    }

    /// The bag the confirm screen shows and, once confirmed, saves. Held as a
    /// value rather than an unsaved `OwnedBean` so an abandoned scan leaves
    /// nothing behind in the model context.
    nonisolated struct Draft: Sendable {
        var displayName: String = ""
        var roasterName: String = ""
        var island: Island?
        var subregion: String = ""
        var processingMethod: ProcessingMethod?
        var roastLevel: RoastLevel?
        var roastDate: Date?
        var weightGrams: Int?
        var scanConfidence: ScanConfidence = .userEntered

        init() {}

        init(_ fields: ScannedBagFields) {
            displayName = fields.name ?? ""
            roasterName = fields.roaster ?? ""
            island = fields.island?.island
            subregion = fields.subregion ?? ""
            processingMethod = fields.processing?.method
            roastLevel = fields.roast?.level
            roastDate = BagScanner.parseDate(fields.roastDate)
            if fields.roastDate != nil, roastDate == nil {
                Log.write(.failure, "roast date \"\(fields.roastDate ?? "")\" did not parse, left blank for the user")
            }
            weightGrams = fields.weightGrams
            // Stays unverified until a human has been through the fields, so
            // a bad scan cannot be compared against the corpus unflagged.
            scanConfidence = .scanUnverified
        }

        var isSaveable: Bool {
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

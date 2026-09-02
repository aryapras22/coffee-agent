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

    @Guide(description: "The roaster or company that packed the bag. Leave empty if the label names no company, and never fall back to the region or the estate.")
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

    /// Growing regions, roaster words and label headings, in both languages.
    /// Language correction rewrites what it does not recognise, and a proper
    /// noun like Bener Meriah is exactly what it would rewrite.
    static let labelVocabulary = [
        "Kopi", "Arabika", "Robusta", "Giling", "Basah", "Sangrai", "Proses",
        "Tanggal", "Berat", "Bersih", "Ketinggian", "Varietas", "Petani",
        "Kebun", "Dataran", "Tinggi", "Diproduksi", "Kemasan", "Biji", "Bubuk",
        "Gayo", "Aceh", "Takengon", "Mandheling", "Mandailing", "Lintong",
        "Sidikalang", "Bener", "Meriah", "Toraja", "Kalosi", "Enrekang",
        "Kintamani", "Bajawa", "Ngada", "Manggarai", "Flores", "Wamena",
        "Baliem", "Preanger", "Malabar", "Pangalengan", "Ijen", "Bondowoso",
    ]

    /// Both languages, Indonesian first, because a bag prints its origin and
    /// process in Indonesian and its marketing copy in English. Vision reads
    /// `recognitionLanguages` as an ordered priority list, so this is the
    /// bilingual case rather than a choice between the two.
    ///
    /// This is why `recognitionLevel` must stay `.accurate`: the `.fast`
    /// recogniser supports six languages, none of them Indonesian, and
    /// dropping to it would silently take the Indonesian half away.
    static func recognitionLanguages(supported: [Locale.Language]) -> [Locale.Language] {
        let preferred = [Locale.Language(identifier: "id"), Locale.Language(identifier: "en-US")]
        let available = preferred.filter { candidate in
            supported.contains { $0.languageCode == candidate.languageCode }
        }
        // An OS without the Indonesian recogniser still reads the bag: the
        // script is Latin either way, only the correction lexicon is lost.
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

    /// Indonesian label terms, longest phrase first so "berat bersih" is not
    /// half-consumed by "berat".
    ///
    /// Only field labels and their values are here. Place names are absent
    /// because they are proper nouns, and so are the product words `kopi`,
    /// `biji` and `bubuk`: a bag named KOPI ARABIKA GAYO is not named
    /// "coffee ARABIKA GAYO", and translating them corrupted the one field
    /// the user is least able to correct from memory.
    static let indonesianTerms: [(String, String)] = [
        ("giling basah", "wet hulled"), ("semi basah", "semi washed"),
        ("cuci penuh", "fully washed"), ("dataran tinggi", "highlands"),
        ("berat bersih", "net weight"), ("tanggal sangrai", "roast date"),
        ("tgl sangrai", "roast date"), ("biji utuh", "whole bean"),
        ("proses", "process"), ("cuci", "washed"), ("alami", "natural"),
        ("madu", "honey"), ("sangrai", "roast"), ("tanggal", "date"),
        ("tgl", "date"), ("gelap", "dark"), ("terang", "light"),
        ("muda", "light"), ("sedang", "medium"), ("berat", "weight"),
        ("ketinggian", "altitude"), ("varietas", "variety"),
        ("petani", "farmer"), ("kebun", "estate"), ("kemasan", "packaged"),
        ("diproduksi", "produced"), ("ketinggian", "altitude"),
        ("Januari", "January"), ("Februari", "February"), ("Maret", "March"),
        ("Mei", "May"), ("Juni", "June"), ("Juli", "July"),
        ("Agustus", "August"), ("Oktober", "October"), ("Desember", "December"),
    ]

    /// Foundation Models does not support Indonesian: handed an Indonesian
    /// prompt it throws `unsupportedLanguageOrLocale` before generating
    /// anything. Substituting the label vocabulary leaves the proper nouns
    /// alone and turns the rest into the English the model does read.
    ///
    /// This is the regex pre-pass the first design rejected. That decision
    /// assumed the model could read the text; it cannot, so the pre-pass is
    /// not an optional second path, it is what makes the first one run.
    static func normalize(_ text: String) -> String {
        indonesianTerms.reduce(text) { partial, pair in
            partial.replacingOccurrences(
                of: "\\b" + NSRegularExpression.escapedPattern(for: pair.0) + "\\b",
                with: pair.1,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return String(text[range])
    }

    /// What the closed label vocabulary yields on its own. Not a replacement
    /// for guided generation, which is what reads the layout and picks the
    /// coffee's name out of the roaster's marketing copy. This is the floor
    /// the user lands on when the model refuses the text outright.
    static func deterministicFields(from normalized: String) -> Draft {
        var draft = Draft()
        draft.scanConfidence = .scanUnverified

        if let weight = firstMatch("\\b\\d{2,4}\\s*(?:g|gr|gram|grams)\\b", in: normalized) {
            draft.weightGrams = Int(weight.filter(\.isNumber))
        }

        for pattern in ["\\b\\d{1,2}\\s+[A-Za-z]+\\s+\\d{4}\\b", "\\b\\d{4}-\\d{2}-\\d{2}\\b", "\\b\\d{1,2}/\\d{1,2}/\\d{4}\\b"] {
            if let found = firstMatch(pattern, in: normalized), let date = parseDate(found) {
                draft.roastDate = date
                break
            }
        }

        // Compound terms first: "semi washed" also contains "washed", and
        // "medium dark" also contains both "medium" and "dark".
        let processes: [(String, ProcessingMethod)] = [
            ("wet hulled", .wetHulled), ("semi washed", .semiWashed),
            ("fully washed", .washed), ("washed", .washed),
            ("honey", .honey), ("natural", .natural),
        ]
        draft.processingMethod = processes.first { normalized.localizedCaseInsensitiveContains($0.0) }?.1

        let roasts: [(String, RoastLevel)] = [
            ("medium dark", .mediumDark), ("medium light", .lightMedium),
            ("light medium", .lightMedium), ("dark", .dark),
            ("light", .light), ("medium", .medium),
        ]
        draft.roastLevel = roasts.first { normalized.localizedCaseInsensitiveContains($0.0) }?.1

        return draft
    }

    /// The whole extraction stage, and it never throws: a model that refuses
    /// the text still has to leave the user a prefilled confirm screen rather
    /// than a dead end.
    static func draft(fromOCR raw: String) async -> Draft {
        let normalized = normalize(raw)
        if normalized != raw {
            Log.write(.scan, "normalised Indonesian label terms before the model saw them")
        }

        do {
            return Draft(try await extract(from: normalized))
        } catch {
            Log.write(.failure, "model extraction unavailable (\(error)), falling back to the label vocabulary")
            return deterministicFields(from: normalized)
        }
    }

    /// A label panel is terse, and terse lines carry weak language signal. The
    /// framework classifies the whole prompt and refuses one it reads as
    /// Indonesian, so a few sentences of ordinary English around the label are
    /// what tip it back. Measured, not guessed: the same panel throws
    /// `unsupportedLanguageOrLocale` without this and passes with it, while the
    /// label lines and the place names each pass on their own.
    static let carrier = """
        The following lines were scanned from the label of a bag of coffee beans. \
        The scan is unreliable, so some words may be misspelled and the lines may \
        be out of order. Read whatever fields the label states and leave the rest empty.

        """

    /// Guided generation over the normalised text. The instructions carry no
    /// Indonesian at all: the language check runs over the whole session, so a
    /// glossary here would trip it just as the raw label did. Translation is
    /// `normalize`'s job, and by this point it has already happened.
    static func extract(from ocrText: String) async throws -> ScannedBagFields {
        let session = LanguageModelSession(
            instructions: """
                You are reading text scanned off a coffee bag from Indonesia.
                Fill only the fields the text actually states. Leave a field empty rather than guessing.
                OCR may have garbled the text, and the lines may be out of order.
                Origin, region and estate names are proper nouns. Copy them as written and never translate them.
                The roaster is the company that packed the bag, not the farmer, the estate, or the growing region.
                The coffee's name is usually the largest text and may be in Indonesian. Copy it as printed.
                Give the roast date as yyyy-MM-dd.
                """
        )
        let fields = try await session.respond(to: Self.carrier + ocrText, generating: ScannedBagFields.self).content
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
        return repairedMonth(in: text)
    }

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// Indonesian spellings as well, for a date that reached here without
    /// passing through `normalize`.
    private static let monthPrefixes: [(String, Int)] = {
        let indonesian = ["jan", "feb", "mar", "apr", "mei", "jun",
                          "jul", "agu", "sep", "okt", "nov", "des"]
        return monthNames.enumerated().map { (String($0.element.prefix(3)).lowercased(), $0.offset + 1) }
            + indonesian.enumerated().map { ($0.element, $0.offset + 1) }
    }()

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
            }
            previous = current
        }
        return previous[b.count]
    }

    /// OCR garbles month names on a matte bag: "01 AUb 2026" is the first of
    /// August. Repairs one only when a single month is within one character of
    /// what was read. Two candidates at the same distance means the date stays
    /// blank, because a confidently wrong roast date is worse than none.
    static func repairedMonth(in text: String) -> Date? {
        guard
            let match = text.range(of: "\\b\\d{1,2}\\s+[A-Za-z]{3,}\\s+\\d{4}\\b", options: [.regularExpression]),
            case let parts = text[match].split(whereSeparator: \.isWhitespace),
            parts.count == 3
        else { return nil }

        let read = String(parts[1].prefix(3)).lowercased()
        let scored = monthPrefixes.map { ($0.1, editDistance(read, $0.0)) }.filter { $0.1 <= 1 }
        let best = scored.map(\.1).min()
        let candidates = Set(scored.filter { $0.1 == best }.map(\.0))
        guard candidates.count == 1, let month = candidates.first else { return nil }

        let repaired = "\(parts[0]) \(monthNames[month - 1]) \(parts[2])"
        Log.write(.scan, "repaired month \"\(parts[1])\" as \(monthNames[month - 1])")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.date(from: repaired)
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

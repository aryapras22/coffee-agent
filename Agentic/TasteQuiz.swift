//
//  TasteQuiz.swift
//  Agentic
//

import Foundation
import FoundationModels

/// Two questions rather than three: the app brews on a moka pot and nothing
/// else, so the brewer question has no branch left to take.
nonisolated enum FeelBranch: String, CaseIterable, Sendable {
    case brightLively, balanced, smoothHeavy

    var label: String {
        switch self {
        case .brightLively: "Bright and lively"
        case .balanced: "Balanced"
        case .smoothHeavy: "Smooth and heavy"
        }
    }

    var targetAcidity: IntensityLevel {
        switch self {
        case .brightLively: .high
        case .balanced: .medium
        case .smoothHeavy: .low
        }
    }

    var flavorChoices: [FlavorNote] {
        switch self {
        case .brightLively: [.citrus, .floral, .fruity]
        case .balanced: [.caramel, .nutty, .chocolate]
        case .smoothHeavy: [.earthy, .spice, .chocolate]
        }
    }
}

nonisolated struct QuizAnswer: Sendable {
    let feel: FeelBranch
    let flavorPull: FlavorNote
}

/// Splits the matches rather than returning one list, so the bright branch can
/// report the compromise instead of silently coming back empty. High-acidity
/// washed lots are exactly the ones a moka pot handles worst, and that tension
/// is a real fact about the brewer, not a bug in the filter.
nonisolated struct QuizResult: Sendable {
    let fit: [BeanProfile]
    let compromised: [BeanProfile]

    var isEmpty: Bool { fit.isEmpty && compromised.isEmpty }
}

nonisolated enum TasteQuiz {
    static func match(_ answer: QuizAnswer, in corpus: [BeanProfile]) -> QuizResult {
        let candidates = corpus
            .filter { $0.acidity == answer.feel.targetAcidity && $0.flavorNotes.contains(answer.flavorPull) }
            .sorted { ($0.cuppingScore ?? 0) > ($1.cuppingScore ?? 0) }

        return QuizResult(
            fit: candidates.filter { $0.mokaPotSuitability != .marginal },
            compromised: candidates.filter { $0.mokaPotSuitability == .marginal }
        )
    }
}

/// Flashcards, built from the domain rather than typed out, so a card can
/// never describe a processing method the corpus no longer uses.
nonisolated struct Flashcard: Identifiable, Sendable {
    let id: String
    let front: String
    let back: String
}

nonisolated enum Flashcards {
    static let processing: [Flashcard] = [
        Flashcard(
            id: "wetHulled",
            front: "What does giling basah mean?",
            back: "Wet-hulled. The parchment comes off while the bean is still wet, then it dries again. Heavy body, low acidity, and the reason Sumatran coffee tastes the way it does."
        ),
        Flashcard(
            id: "washed",
            front: "What defines washed processing?",
            back: "The fruit is removed completely before drying. The cleanest and brightest of the main methods, and the hardest of them to get right on a moka pot."
        ),
        Flashcard(
            id: "natural",
            front: "What is natural processing?",
            back: "The cherry dries whole around the bean. Fruit-forward and heavy, with more cup-to-cup variation than washed."
        ),
        Flashcard(
            id: "honey",
            front: "What is honey processing?",
            back: "Some mucilage is left on the bean while it dries. Yellow, red and black honey differ by how long that fermentation runs."
        ),
        Flashcard(
            id: "semiWashed",
            front: "How does semi-washed differ from wet-hulled?",
            back: "Both skip a full wash, but semi-washed dries in parchment before hulling. It keeps more acidity than giling basah does."
        ),
    ]

    static let mokaPot: [Flashcard] = [
        Flashcard(
            id: "gurgle",
            front: "When do you take a moka pot off the heat?",
            back: "At the first gurgle, before the sound turns to a hiss. Everything after that point is over-extracted and bitter."
        ),
        Flashcard(
            id: "tamp",
            front: "Should you tamp a moka pot basket?",
            back: "Never. The pot runs at about 1.5 bar, nothing like espresso pressure, and a tamped bed simply blocks the flow."
        ),
        Flashcard(
            id: "preheat",
            front: "Why preheat the water?",
            back: "Cold water sits on the flame while the whole pot heats, and the grounds cook in the rising steam. Preheating is the single best fix for bitterness."
        ),
    ]

    static let all: [Flashcard] = processing + mokaPot
}

@Generable
enum QuizFeelArgument {
    case brightLively, balanced, smoothHeavy

    var branch: FeelBranch {
        switch self {
        case .brightLively: .brightLively
        case .balanced: .balanced
        case .smoothHeavy: .smoothHeavy
        }
    }
}

@Generable
enum QuizStatus {
    case matchesFound
    /// Everything matching the taste is rated marginal on a moka pot. The
    /// model is told to name the compromise rather than report no results.
    case onlyCompromisedMatches
    case noMatches
}

@Generable
struct QuizOutcome {
    var status: QuizStatus
    var matches: [BeanHit]
    var compromised: [BeanHit]
    var note: String
}

struct TasteQuizTool: Tool {
    let name = "matchTasteProfile"
    let description =
        "Matches a taste preference to Indonesian beans, filtered for moka pot. Call once the user has said how the cup should feel (bright, balanced, or smooth) and which flavor pulls them in."

    let store: BeanProfileStore
    let log: CardLog

    @Generable
    struct Arguments {
        @Guide(description: "How the user wants the cup to feel")
        var feel: QuizFeelArgument

        @Guide(description: "The flavor the user is drawn to")
        var flavorPull: FlavorNoteArgument

        @Guide(description: "How many beans to return", .range(1...5))
        var limit: Int
    }

    func call(arguments: Arguments) async throws -> QuizOutcome {
        Log.write(.quiz, "matchTasteProfile feel=\(arguments.feel.branch.rawValue) flavor=\(arguments.flavorPull.note.rawValue) limit=\(arguments.limit)")
        let corpus = await store.allProfiles()
        let result = TasteQuiz.match(
            QuizAnswer(feel: arguments.feel.branch, flavorPull: arguments.flavorPull.note),
            in: corpus
        )

        let fit = result.fit.prefix(arguments.limit).map(BeanCorpusTool.hit)
        let compromised = result.compromised.prefix(arguments.limit).map(BeanCorpusTool.hit)

        Log.write(.quiz, "fit \(result.fit.count), marginal on a moka pot \(result.compromised.count)")

        if !fit.isEmpty {
            await log.append(result.fit.prefix(arguments.limit).map { .bean(BeanCard($0)) })
            return QuizOutcome(
                status: .matchesFound,
                matches: Array(fit),
                compromised: [],
                note: "Filtered for moka pot suitability."
            )
        }
        if !compromised.isEmpty {
            Log.write(.quiz, "onlyCompromisedMatches, surfacing the compromise rather than an empty answer")
            await log.append(result.compromised.prefix(arguments.limit).map { .bean(BeanCard($0)) })
            return QuizOutcome(
                status: .onlyCompromisedMatches,
                matches: [],
                compromised: Array(compromised),
                note: "Every bean matching this taste is rated marginal on a moka pot. Bright, high-acidity washed lots are the ones this brewer handles worst. Say so plainly and let the user decide."
            )
        }
        Log.write(.quiz, "noMatches for that feel and flavour")
        return QuizOutcome(status: .noMatches, matches: [], compromised: [], note: "No bean in the corpus matches that combination.")
    }
}

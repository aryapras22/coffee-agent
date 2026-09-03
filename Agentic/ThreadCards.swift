//
//  ThreadCards.swift
//  Agentic
//

import Foundation
import FoundationModels

/// A result a tool found, drawn in the thread underneath the reply that used
/// it. The model gets prose and the reader gets the same facts as a card, so
/// a cupping score or a roast date is read off the corpus rather than off a
/// sentence the model composed about it.
///
/// Persisted on `ChatMessage` alongside the trace, so scrolling back redraws
/// what the run actually showed instead of an empty bubble.
nonisolated enum ThreadCard: Codable, Identifiable, Sendable {
    case bean(BeanCard)
    case owned(OwnedCard)
    case comparison(ComparisonCard)
    case seller(SellerCard)
    case flashcard(FlashcardCard)
    case choices(ChoiceCard)

    /// Stable across decodes: `displayMessages` decodes on every read, so a
    /// generated identifier would give `ForEach` a new identity each frame.
    var id: String {
        switch self {
        case .bean(let card): "bean-" + card.id
        case .owned(let card): "owned-" + card.id.uuidString
        case .comparison(let card): "compare-" + card.beanName
        case .seller(let card): "seller-" + card.name
        case .flashcard(let card): "card-" + card.id
        case .choices(let card): "choices-" + card.question
        }
    }
}

nonisolated struct BeanCard: Codable, Sendable {
    let id: String
    let name: String
    let island: String
    let subregion: String
    let altitude: String?
    let processing: String
    let flavors: [String]
    let acidity: String
    let body: String
    /// Nil where the corpus carries no verified roast, which the card says in
    /// words rather than leaving the row blank.
    let roast: String?
    let mokaPot: String
    let cuppingScore: Double?
    let source: String

    init(_ profile: BeanProfile) {
        id = profile.id
        name = profile.name
        island = profile.island.label
        subregion = profile.subregion
        altitude = profile.altitudeDescription
        processing = profile.processingMethod.label
        flavors = profile.flavorNotes.map(\.label)
        acidity = profile.acidity.label
        body = profile.body.label
        roast = profile.roastRecommendation?.label
        mokaPot = profile.mokaPotSuitability.label
        cuppingScore = profile.cuppingScore
        source = profile.dataSource.label
    }
}

nonisolated struct OwnedCard: Codable, Sendable {
    let id: UUID
    let name: String
    let roaster: String?
    let origin: String?
    let daysSinceRoast: Int?
    let grade: String?
    let grind: String
    let grindAdjustable: Bool
    let remainingGrams: Int?
    let brewCount: Int
    let brewsAwaitingReview: Int
    let provenance: String
    let isUnverified: Bool
    /// The corpus lot this bag was linked to, or nil when nothing matched. A
    /// card that says "no corpus link" is telling the truth about what the
    /// comparison can and cannot do.
    let corpusLink: String?

    init(_ bean: OwnedBeanSnapshot, corpusLink: String?) {
        id = bean.id
        name = bean.displayName
        roaster = bean.roasterName
        origin = [bean.subregion, bean.island?.label]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
            .nilWhenEmpty
        daysSinceRoast = bean.daysSinceRoast
        grade = bean.grade
        grind = bean.grindSize.label
        grindAdjustable = bean.grindSize.isAdjustable
        remainingGrams = bean.remainingGrams
        brewCount = bean.brewCount
        brewsAwaitingReview = bean.brewsAwaitingReview
        provenance = bean.scanConfidence.label
        isUnverified = bean.scanConfidence == .scanUnverified
        self.corpusLink = corpusLink
    }
}

/// Three sources on one bean, deliberately left disagreeing. Reconciling them
/// would throw away the useful part: where the published profile, the
/// roaster's copy and the user's own palate diverge is the whole point.
nonisolated struct ComparisonCard: Codable, Sendable {
    let beanName: String
    let corpusName: String?
    let corpusSays: [String]
    let roasterSays: [String]
    let youTasted: [String]
    /// What the reader should not conclude from the rows above.
    let caveat: String?
}

nonisolated struct SellerCard: Codable, Sendable {
    let name: String
    let detail: String
    let url: String?
    let source: String
}

nonisolated struct FlashcardCard: Codable, Sendable {
    let id: String
    let front: String
    let back: String

    init(_ card: Flashcard) {
        id = card.id
        front = card.front
        back = card.back
    }
}

/// Options the agent offered with a question, so answering is a tap. Only the
/// agent creates these: a guessed list of replies under a question it never
/// asked would put words in its mouth.
nonisolated struct ChoiceCard: Codable, Sendable {
    let question: String
    let options: [String]
}

/// The same side channel `PlaceLog` uses, for the same reason: a tool runs
/// deep inside a model turn with nowhere to return a second value to, so it
/// writes here and `ChatManager` drains it once the turn is over.
actor CardLog {
    private(set) var cards: [ThreadCard] = []

    /// Appends rather than replaces, because one turn can call several tools
    /// and every result belongs under the same reply.
    func append(_ found: [ThreadCard]) {
        cards.append(contentsOf: found)
    }

    func reset() {
        cards = []
    }
}

/// What to offer next, off the cards the turn produced. Derived rather than
/// generated: the follow-ups that make sense after a bean card are always the
/// same three, and spending a model call on them would add latency to every
/// turn for a fixed answer.
nonisolated enum QuickReplies {
    /// Always shown, never empty. The bar is a standing menu of what the app
    /// can do, not a prompt that appears and vanishes, so there is always
    /// somewhere to go from a blank thread or a failed turn.
    static let opening = [
        "Recommend a bean",
        "What do I have?",
        "Scan a bag",
        "Start brewing",
        "My coffee tastes bitter",
        "Compare my notes",
        "Teach me something",
        "Where can I buy beans?",
    ]

    /// The follow-ups a turn earned, then the standing menu behind them, so
    /// sliding right always reaches the rest of the app.
    static func following(_ cards: [ThreadCard]) -> [String] {
        let led = lead(cards)
        return led + opening.filter { !led.contains($0) }
    }

    private static func lead(_ cards: [ThreadCard]) -> [String] {
        // An explicit question outranks anything derived: the agent asked
        // something, and the reader's next move is to answer it.
        if let choices = cards.compactMap(\.choiceCard).last {
            return choices.options
        }

        var replies: [String] = []
        for card in cards {
            switch card {
            case .bean:
                replies = ["Start brewing", "Where can I buy this?", "Scan a bag"]
            case .owned(let owned):
                replies = owned.brewsAwaitingReview > 0
                    ? ["Review my brews", "Start brewing", "Compare my notes"]
                    : ["Start brewing", "What grind should I use?", "Compare my notes"]
            case .comparison:
                replies = ["Start brewing", "What do I have?"]
            case .seller:
                replies = ["What do I have?", "Scan a bag"]
            case .flashcard:
                replies = ["Another card", "Recommend a bean"]
            case .choices:
                break
            }
        }
        return replies
    }
}

nonisolated extension ThreadCard {
    fileprivate var choiceCard: ChoiceCard? {
        if case .choices(let card) = self { return card }
        return nil
    }
}

nonisolated extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

/// Lets the model turn its own question into tappable options. Without it the
/// chips could only ever be guessed from the cards, and the two-question taste
/// quiz has no cards until it is over.
struct OfferChoicesTool: Tool {
    let name = "offerChoices"
    let description =
        "Shows the user a short list of tappable answers to a question you are asking. Use when eliciting, such as the two taste quiz questions or narrowing down what caused a bad cup. Ask the question in your reply as well."

    let log: CardLog

    @Generable
    struct Arguments {
        @Guide(description: "The question being asked, in a few words")
        var question: String

        @Guide(description: "The answers to offer, each a short phrase the user could have typed", .count(2...4))
        var options: [String]
    }

    @Generable
    struct Outcome {
        var shown: Int
    }

    func call(arguments: Arguments) async throws -> Outcome {
        let options = arguments.options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        Log.write(.tool, "offerChoices \"\(arguments.question)\" -> \(options.joined(separator: " | "))")
        await log.append([.choices(ChoiceCard(question: arguments.question, options: options))])
        return Outcome(shown: options.count)
    }
}

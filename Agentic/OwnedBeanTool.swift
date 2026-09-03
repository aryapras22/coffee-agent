//
//  OwnedBeanTool.swift
//  Agentic
//

import Foundation
import FoundationModels

/// Snapshots of what the user owns, refreshed on the main actor before each
/// turn. The tool runs inside a model turn with no `ModelContext` of its own,
/// so it reads copies here rather than reaching into SwiftData off-actor.
actor Cupboard {
    private(set) var beans: [OwnedBeanSnapshot] = []
    private(set) var sessions: [BrewSessionSnapshot] = []

    func replace(beans: [OwnedBeanSnapshot], sessions: [BrewSessionSnapshot]) {
        self.beans = beans
        self.sessions = sessions
    }

    func sessions(forBean id: UUID) -> [BrewSessionSnapshot] {
        sessions.filter { $0.beanId == id }
    }
}

@Generable
enum OwnedBeanStatus {
    /// The cupboard holds nothing at all, which is not the same as the filter
    /// excluding everything.
    case cupboardEmpty
    case matchesFound
    case noMatchesOwned
}

@Generable
struct OwnedBeanHit {
    var name: String
    var roaster: String?
    var origin: String?
    var daysSinceRoast: Int?
    var remainingGrams: Int?
    var brewsLogged: Int
    /// Brews from this bag that the user has not said anything about yet. The
    /// agent is told to offer to collect them, because an unreviewed brew is
    /// dial-in evidence that has not been recorded.
    var brewsAwaitingReview: Int
    var bestRating: Int?
    var tastedFlavors: String
    /// Says whether a human ever checked the scanned fields. The model is told
    /// not to compare an unverified bag against the corpus without flagging it.
    var provenance: String
}

/// Three sources on one bean, left disagreeing. The model is told not to
/// reconcile them, because the divergence between a published profile, a
/// roaster's copy and the user's own palate is the answer, not noise in it.
@Generable
struct BeanComparison {
    var beanName: String
    /// Nil when the bag was never matched to a reference lot, which is not the
    /// same as the profile disagreeing.
    var corpusSays: String?
    var roasterSays: String?
    var youTasted: String?
    /// What the reader must not conclude from the rows above.
    var caveat: String?
}

@Generable
struct OwnedBeanOutcome {
    var status: OwnedBeanStatus
    var beans: [OwnedBeanHit]
    /// Present only when the caller asked to compare. Folded in here rather
    /// than given its own tool: it reads the same cupboard through the same
    /// filters, and a separate tool cost the context window another schema.
    var comparison: BeanComparison?
}

/// Separate from `BeanCorpusTool` because the two empty results mean different
/// things: no such bean exists, versus you do not own one.
struct OwnedBeanTool: Tool {
    let name = "searchOwnedBeans"
    let description =
        "Searches the bags the user actually owns. Use for what is in the cupboard now, what is freshest, what was rated highest, or what has never been brewed."

    let cupboard: Cupboard
    let store: BeanProfileStore
    let log: CardLog

    @Generable
    struct Arguments {
        @Guide(description: "Flavor note the user has tasted in the bean, if they named one")
        var flavorNote: FlavorNoteArgument?

        @Guide(description: "Indonesian island, if the user named one")
        var island: IslandArgument?

        @Guide(description: "Only beans roasted within this many days", .range(1...365))
        var maxDaysSinceRoast: Int?

        @Guide(description: "Only beans rated at least this highly", .range(1...5))
        var minRating: Int?

        @Guide(description: "Only beans that have never been brewed")
        var neverBrewed: Bool?

        @Guide(description: "Exclude bags the user has finished")
        var onlyWithCoffeeLeft: Bool?

        @Guide(description: "Also compare the first match against its reference profile and the roaster's printed notes. Use when the user asks how a bean compares to what it was supposed to taste like.")
        var compareToReference: Bool?
    }

    func call(arguments: Arguments) async throws -> OwnedBeanOutcome {
        let owned = await cupboard.beans
        guard !owned.isEmpty else {
            Log.write(.tool, "searchOwnedBeans cupboardEmpty")
            return OwnedBeanOutcome(status: .cupboardEmpty, beans: [], comparison: nil)
        }

        let query = OwnedBeanQuery(
            flavorNote: arguments.flavorNote?.note,
            island: arguments.island?.island,
            maxDaysSinceRoast: arguments.maxDaysSinceRoast,
            minRating: arguments.minRating,
            neverBrewed: arguments.neverBrewed ?? false,
            hasRemaining: arguments.onlyWithCoffeeLeft ?? true
        )

        Log.write(.tool, "searchOwnedBeans flavor=\(query.flavorNote?.rawValue ?? "any") island=\(query.island?.rawValue ?? "any") maxDays=\(query.maxDaysSinceRoast.map(String.init) ?? "any") minRating=\(query.minRating.map(String.init) ?? "any") neverBrewed=\(query.neverBrewed) over \(owned.count) bags")

        let matched = OwnedBeanSearch.matches(query, in: owned)
        guard !matched.isEmpty else {
            Log.write(.tool, "searchOwnedBeans noMatchesOwned")
            return OwnedBeanOutcome(status: .noMatchesOwned, beans: [], comparison: nil)
        }
        Log.write(.tool, "searchOwnedBeans matchesFound \(matched.count): \(matched.map(\.displayName).joined(separator: ", "))")

        // Resolved in one hop to the corpus actor rather than one per bag.
        // Two bags can reference the same lot, so the names are merged rather
        // than keyed uniquely, which would trap.
        let linkedNames = Dictionary(
            await store.profiles(for: matched.compactMap(\.corpusReferenceId)).map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        var cards = matched.map { bean in
            ThreadCard.owned(OwnedCard(bean, corpusLink: bean.corpusReferenceId.flatMap { linkedNames[$0] }))
        }
        // The first match only. Comparing every bag in a broad search would
        // cost more context than the answer is worth; narrowing the search is
        // how the user picks a different one.
        var comparison: BeanComparison?
        if arguments.compareToReference == true, let bean = matched.first {
            var profile: BeanProfile?
            if let id = bean.corpusReferenceId {
                profile = await store.profile(id: id)
            }
            comparison = Self.compare(bean, against: profile)
            cards.append(
                .comparison(
                    ComparisonCard(
                        beanName: bean.displayName,
                        corpusName: profile?.name,
                        corpusSays: profile?.flavorNotes.map(\.label) ?? [],
                        roasterSays: bean.roasterNotes,
                        youTasted: bean.tastedFlavors.map(\.label).sorted(),
                        caveat: comparison?.caveat
                    )
                )
            )
        }

        await log.append(cards)
        Log.write(.tool, "searchOwnedBeans returned \(cards.count) cards\(comparison == nil ? "" : ", with a comparison")")

        return OwnedBeanOutcome(
            status: .matchesFound,
            beans: matched.map { bean in
                OwnedBeanHit(
                    name: bean.displayName,
                    roaster: bean.roasterName,
                    origin: [bean.subregion, bean.island?.label]
                        .compactMap { $0 }
                        .joined(separator: ", ")
                        .nilIfEmpty,
                    daysSinceRoast: bean.daysSinceRoast,
                    remainingGrams: bean.remainingGrams,
                    brewsLogged: bean.brewCount,
                    brewsAwaitingReview: bean.brewsAwaitingReview,
                    bestRating: bean.bestRating,
                    tastedFlavors: bean.tastedFlavors.map(\.label).joined(separator: ", "),
                    provenance: bean.scanConfidence.label
                )
            },
            comparison: comparison
        )
    }

    /// Only flagged when there is something to flag: the caveat exists to
    /// explain a row that does not line up, not as boilerplate.
    static func compare(_ bean: OwnedBeanSnapshot, against profile: BeanProfile?) -> BeanComparison {
        let unmappable = bean.roasterNotes.filter { note in
            !FlavorNote.allCases.contains { $0.label.localizedCaseInsensitiveCompare(note) == .orderedSame }
        }

        return BeanComparison(
            beanName: bean.displayName,
            corpusSays: profile?.flavorNotes.map(\.label).joined(separator: ", ").nilWhenEmpty,
            roasterSays: bean.roasterNotes.joined(separator: ", ").nilWhenEmpty,
            youTasted: bean.tastedFlavors.map(\.label).sorted().joined(separator: ", ").nilWhenEmpty,
            caveat: unmappable.isEmpty
                ? nil
                : "The roaster's \(unmappable.joined(separator: " and ")) are cupping attributes, not flavours, so they are kept as printed."
        )
    }
}

/// The domain enums are not `@Generable`, and making them so would put their
/// case names in the corpus decoder's path as well. These mirrors exist only
/// as tool arguments.
@Generable
enum FlavorNoteArgument {
    case chocolate, earthy, floral, citrus, spice, tobacco
    case caramel, nutty, fruity, woody, herbal, cedar

    var note: FlavorNote {
        switch self {
        case .chocolate: .chocolate
        case .earthy: .earthy
        case .floral: .floral
        case .citrus: .citrus
        case .spice: .spice
        case .tobacco: .tobacco
        case .caramel: .caramel
        case .nutty: .nutty
        case .fruity: .fruity
        case .woody: .woody
        case .herbal: .herbal
        case .cedar: .cedar
        }
    }
}

@Generable
enum IslandArgument {
    case sumatra, java, sulawesi, bali, flores, papua

    var island: Island {
        switch self {
        case .sumatra: .sumatra
        case .java: .java
        case .sulawesi: .sulawesi
        case .bali: .bali
        case .flores: .flores
        case .papua: .papua
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

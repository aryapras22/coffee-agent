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

@Generable
struct OwnedBeanOutcome {
    var status: OwnedBeanStatus
    var beans: [OwnedBeanHit]
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
    }

    func call(arguments: Arguments) async throws -> OwnedBeanOutcome {
        let owned = await cupboard.beans
        guard !owned.isEmpty else {
            Log.write(.tool, "searchOwnedBeans cupboardEmpty")
            return OwnedBeanOutcome(status: .cupboardEmpty, beans: [])
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
            return OwnedBeanOutcome(status: .noMatchesOwned, beans: [])
        }
        Log.write(.tool, "searchOwnedBeans matchesFound \(matched.count): \(matched.map(\.displayName).joined(separator: ", "))")

        // Resolved in one hop to the corpus actor rather than one per bag.
        // Two bags can reference the same lot, so the names are merged rather
        // than keyed uniquely, which would trap.
        let linkedNames = Dictionary(
            await store.profiles(for: matched.compactMap(\.corpusReferenceId)).map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let cards = matched.map { bean in
            ThreadCard.owned(OwnedCard(bean, corpusLink: bean.corpusReferenceId.flatMap { linkedNames[$0] }))
        }
        await log.append(cards)
        Log.write(.tool, "searchOwnedBeans returned \(cards.count) cards")

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
            }
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

@Generable
enum ComparisonStatus {
    case compared
    case beanNotOwned
    /// The bag has no link into the reference corpus, so there is no published
    /// profile to compare against. Not the same as the profile disagreeing.
    case noCorpusLink
    /// Nothing has been tasted yet, so the third column would be empty.
    case noTastingNotes
}

@Generable
struct ComparisonOutcome {
    var status: ComparisonStatus
    var beanName: String
    var corpusSays: String?
    var roasterSays: String?
    var youTasted: String?
    /// What the reader must not conclude. Roaster copy is marketing prose, and
    /// some of it names cupping attributes rather than flavours.
    var caveat: String?
}

/// Three sources on one bean, left disagreeing. The model is told not to
/// reconcile them, because the divergence between a published profile, a
/// roaster's copy and the user's own palate is the answer, not noise in it.
struct CompareTastingTool: Tool {
    let name = "compareTastingNotes"
    let description =
        "Puts the reference corpus profile, the roaster's printed notes, and what the user actually tasted side by side for one owned bag. Use when the user asks how a bean compares to what it was supposed to taste like."

    let cupboard: Cupboard
    let store: BeanProfileStore
    let log: CardLog

    @Generable
    struct Arguments {
        @Guide(description: "Name of the owned bag to compare. Leave empty for the most recently added one.")
        var beanName: String?
    }

    func call(arguments: Arguments) async throws -> ComparisonOutcome {
        let owned = await cupboard.beans
        let name = arguments.beanName?.trimmingCharacters(in: .whitespacesAndNewlines)

        let bean: OwnedBeanSnapshot?
        if let name, !name.isEmpty {
            bean = owned.first { $0.displayName.localizedCaseInsensitiveContains(name) }
        } else {
            bean = owned.first
        }

        guard let bean else {
            Log.write(.tool, "compareTastingNotes beanNotOwned \(name ?? "none")")
            return ComparisonOutcome(status: .beanNotOwned, beanName: name ?? "", corpusSays: nil, roasterSays: nil, youTasted: nil, caveat: nil)
        }

        var profile: BeanProfile?
        if let id = bean.corpusReferenceId {
            profile = await store.profile(id: id)
        }
        let corpusSays = profile?.flavorNotes.map(\.label) ?? []
        let tasted = bean.tastedFlavors.map(\.label).sorted()

        // Only flagged when there is something to flag: the caveat exists to
        // explain a row that does not line up, not as boilerplate.
        let unmappable = bean.roasterNotes.filter { note in
            !FlavorNote.allCases.contains { $0.label.localizedCaseInsensitiveCompare(note) == .orderedSame }
        }
        let caveat = unmappable.isEmpty
            ? nil
            : "The roaster's \(unmappable.joined(separator: " and ")) are cupping attributes, not flavours, so they are kept as printed rather than filed under a flavour note."

        await log.append([
            .comparison(
                ComparisonCard(
                    beanName: bean.displayName,
                    corpusName: profile?.name,
                    corpusSays: corpusSays,
                    roasterSays: bean.roasterNotes,
                    youTasted: tasted,
                    caveat: caveat
                )
            )
        ])

        let status: ComparisonStatus =
            profile == nil ? .noCorpusLink : (tasted.isEmpty ? .noTastingNotes : .compared)
        Log.write(.tool, "compareTastingNotes \(bean.displayName) status=\(status) corpus=\(corpusSays.count) roaster=\(bean.roasterNotes.count) tasted=\(tasted.count)")

        return ComparisonOutcome(
            status: status,
            beanName: bean.displayName,
            corpusSays: corpusSays.joined(separator: ", ").nilWhenEmpty,
            roasterSays: bean.roasterNotes.joined(separator: ", ").nilWhenEmpty,
            youTasted: tasted.joined(separator: ", ").nilWhenEmpty,
            caveat: caveat
        )
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

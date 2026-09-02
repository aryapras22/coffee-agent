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

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

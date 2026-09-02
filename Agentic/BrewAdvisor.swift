//
//  BrewAdvisor.swift
//  Agentic
//

import Foundation
import FoundationModels

/// The brew rules, as pure functions over session history. Deterministic on
/// purpose: the same history has to produce the same advice every time, which
/// a model call cannot promise.
nonisolated enum BrewAdvisor {

    // MARK: Dial-in

    nonisolated struct GrindAdvice: Sendable {
        enum Direction: String, Sendable {
            case coarser, finer, hold, unknown
        }

        let direction: Direction
        let message: String
    }

    /// Established practice is to move only the grind between brews and hold
    /// everything else, which usually lands in two to four attempts.
    static func nextGrind(from history: [BrewSessionSnapshot]) -> GrindAdvice {
        let rated = history
            .filter { $0.outcome != nil }
            .sorted { $0.date > $1.date }

        guard let last = rated.first, let outcome = last.outcome else {
            return GrindAdvice(
                direction: .unknown,
                message: "No rated brews for this bean yet. Start at your usual setting and change nothing else, so the next cup tells you something."
            )
        }

        return advice(for: outcome.symptom, grind: last.grindSetting.isEmpty ? "your last setting" : last.grindSetting)
    }

    /// Split out of `nextGrind` so a symptom the user has just described can
    /// reach the same rule table without a logged session to carry it.
    static func advice(for symptom: BrewSymptom?, grind: String) -> GrindAdvice {
        switch symptom {
        case .bitter, .burnt:
            return GrindAdvice(
                direction: .coarser,
                message: "That brew at \(grind) came out \(symptom == .burnt ? "burnt" : "bitter"). Go one step coarser and keep the heat and dose identical."
            )
        case .sour, .weak:
            return GrindAdvice(
                direction: .finer,
                message: "That brew at \(grind) came out \(symptom == .sour ? "sour" : "weak"). Go one step finer and keep the heat and dose identical."
            )
        // Both are bed-prep or hardware faults. Sending the user to the grinder
        // would cost them several brews chasing the wrong variable.
        case .channeling:
            return GrindAdvice(
                direction: .hold,
                message: "That was channeling, not grind. Level the bed with a finger, do not tamp, and clear the rim before sealing. Keep \(grind)."
            )
        case .sputtering:
            return GrindAdvice(
                direction: .hold,
                message: "Check the gasket and the water line before touching the grind. Keep \(grind)."
            )
        case .balanced, .none:
            return GrindAdvice(
                direction: .hold,
                message: "\(grind) is working. Lock it in as the baseline for this bean."
            )
        }
    }

    /// A starting point for a bean never brewed before, off the roast alone.
    static func startingPoint(for roast: RoastLevel?) -> String {
        let base = "Medium-fine, about the texture of table salt."
        guard let roast else { return base }
        if roast.darkness >= RoastLevel.mediumDark.darkness {
            return base + " This is a dark roast, so start one to two steps coarser than that."
        }
        if roast.darkness <= RoastLevel.lightMedium.darkness {
            return base + " This is a light roast, so start one to two steps finer than that."
        }
        return base
    }

    // MARK: Troubleshooting

    nonisolated struct Remedy: Sendable {
        let cause: String
        let fix: String
    }

    static func remedy(for symptom: BrewSymptom) -> Remedy? {
        switch symptom {
        case .balanced:
            nil
        case .bitter, .burnt:
            Remedy(
                cause: "Grind too fine, heat too high, or the pot left on the stove after it finished.",
                fix: "Go one step coarser, drop to medium-low heat, pull at the first gurgle, and cool the base under running water."
            )
        case .weak, .sour:
            Remedy(
                cause: "Grind too coarse, heat too low, or a clogged filter plate.",
                fix: "Go one step finer or raise the heat slightly, clean the filter, and fill the basket completely without packing it."
            )
        case .channeling:
            Remedy(
                cause: "Water is cutting a path through the bed instead of soaking it, which tastes bitter and sour at once.",
                fix: "Level the bed, never tamp, and clear stray grounds off the rim. Leave the grind alone."
            )
        case .sputtering:
            Remedy(
                cause: "A worn gasket, or water filled above the safety valve.",
                fix: "Replace the gasket every three to six months of daily use and fill only to the valve line. Leave the grind alone."
            )
        }
    }

    // MARK: Phase timings

    /// A correctly dialed moka pot starts flowing around fifty to sixty
    /// seconds. Reading that off a timestamp is the whole point of capturing
    /// the phases rather than running a blind countdown.
    static func firstDripVerdict(seconds: Int) -> String {
        switch seconds {
        case ..<40: "That is early. The heat was too high, which is the usual cause of a bitter cup."
        case 40...150: "Right in range."
        default: "That is slow. The grind is likely choking the basket, or the heat is too low."
        }
    }

    static func totalVerdict(seconds: Int) -> String {
        switch seconds {
        case ..<180: "Quick, but fine if it tasted right."
        case 180...420: "Normal total time on heat."
        default: "Longer than it should sit on heat. Drop the flame next time."
        }
    }

    // MARK: Fixed parameters

    /// The moka pot variables that never change, so the agent quotes one table
    /// rather than reciting whatever it remembers.
    static let parameters: [(String, String)] = [
        ("Ratio", "Basket-determined, roughly 1:10 to 1:12. About 25-30g for 300ml on a six-cup."),
        ("Grind", "Medium-fine, table-salt texture. Finer than pour-over, coarser than espresso."),
        ("Loading", "Fill the basket level. Never tamp."),
        ("Water", "Preheated, filled to just under the safety valve."),
        ("Heat", "Medium-low the whole way."),
        ("Stop point", "The first gurgle, before the sound turns to a hiss."),
    ]
}

@Generable
enum BrewAdviceStatus {
    case adviceFromHistory
    case noHistoryForBean
    case beanNotOwned
    /// The symptom alone decided the answer, without reading any history.
    case ruleMatched
}

@Generable
enum BrewSymptomArgument {
    case balanced, bitter, sour, weak, burnt
    /// Bitter and sour in the same cup.
    case channeling
    /// The pot spits or leaks while brewing.
    case sputtering

    var symptom: BrewSymptom {
        switch self {
        case .balanced: .balanced
        case .bitter: .bitter
        case .sour: .sour
        case .weak: .weak
        case .burnt: .burnt
        case .channeling: .channeling
        case .sputtering: .sputtering
        }
    }
}

@Generable
struct BrewAdviceOutcome {
    var status: BrewAdviceStatus
    /// The deterministic advice, verbatim. Passing it on unchanged is the
    /// point: the rule table is what makes the answer reproducible.
    var advice: String
    var grindDirection: String
    var lastGrindSetting: String?
    var ratedBrews: Int
    var cause: String?
}

/// Wraps `BrewAdvisor` so the agent can reach it and the trace records that it
/// did, rather than the model improvising grind advice from its own knowledge.
struct BrewAdviceTool: Tool {
    let name = "adviseNextGrind"
    let description =
        "Reads the user's logged moka pot brews for one bean and returns the deterministic grind adjustment for the next one. Use whenever the user asks what to change, or reports how a brew tasted."

    let cupboard: Cupboard

    @Generable
    struct Arguments {
        @Guide(description: "How the brew went wrong, if the user described it")
        var symptom: BrewSymptomArgument?

        @Guide(description: "Name of the owned bean to advise on. Leave empty for the most recently brewed bean.")
        var beanName: String?
    }

    func call(arguments: Arguments) async throws -> BrewAdviceOutcome {
        // A symptom the user just described beats whatever the history says,
        // because it is about the cup in front of them.
        if let reported = arguments.symptom?.symptom {
            let advice = BrewAdvisor.advice(for: reported, grind: "your current setting")
            Log.write(.tool, "adviseNextGrind ruleMatched symptom=\(reported.rawValue) direction=\(advice.direction.rawValue)")
            return BrewAdviceOutcome(
                status: .ruleMatched,
                advice: BrewAdvisor.remedy(for: reported)?.fix ?? advice.message,
                grindDirection: advice.direction.rawValue,
                lastGrindSetting: nil,
                ratedBrews: 0,
                cause: BrewAdvisor.remedy(for: reported)?.cause
            )
        }

        let beans = await cupboard.beans
        let allSessions = await cupboard.sessions

        let bean: OwnedBeanSnapshot?
        if let name = arguments.beanName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            bean = beans.first { $0.displayName.localizedCaseInsensitiveContains(name) }
            guard bean != nil else {
                return BrewAdviceOutcome(
                    status: .beanNotOwned,
                    advice: "There is no bag by that name in the cupboard.",
                    grindDirection: BrewAdvisor.GrindAdvice.Direction.unknown.rawValue,
                    lastGrindSetting: nil,
                    ratedBrews: 0,
                    cause: nil
                )
            }
        } else {
            let mostRecent = allSessions.sorted { $0.date > $1.date }.first
            bean = beans.first { $0.id == mostRecent?.beanId }
        }

        let history = allSessions.filter { $0.beanId == bean?.id }
        let advice = BrewAdvisor.nextGrind(from: history)
        let rated = history.filter { $0.outcome != nil }
        Log.write(.tool, "adviseNextGrind bean=\(bean?.displayName ?? "none") rated=\(rated.count)/\(history.count) direction=\(advice.direction.rawValue)")

        return BrewAdviceOutcome(
            status: rated.isEmpty ? .noHistoryForBean : .adviceFromHistory,
            advice: rated.isEmpty
                ? advice.message + " " + BrewAdvisor.startingPoint(for: bean?.roastLevel)
                : advice.message,
            grindDirection: advice.direction.rawValue,
            lastGrindSetting: rated.sorted { $0.date > $1.date }.first?.grindSetting,
            ratedBrews: rated.count,
            cause: rated.first?.outcome?.symptom.flatMap { BrewAdvisor.remedy(for: $0)?.cause }
        )
    }
}

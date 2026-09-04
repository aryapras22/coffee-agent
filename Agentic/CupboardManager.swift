//
//  CupboardManager.swift
//  Agentic
//

import Foundation
import Observation
import SwiftData
import UIKit

/// Owns the bags and the brews: the `ModelContext` for them, and the job of
/// pushing snapshots into the agent's `Cupboard` after every change. Kept
/// apart from `ChatManager` because nothing here is about a conversation, and
/// because every mutation has to reach the agent, not just the ones a chat
/// turn happens to follow.
@Observable
@MainActor
final class CupboardManager {
    private(set) var beans: [OwnedBean] = []
    private(set) var sessions: [BrewSession] = []
    private(set) var failure: String?

    /// The brew currently running, held here rather than in a view so the
    /// timer keeps ticking while the reader scrolls the transcript, switches
    /// chats, or opens the cupboard. A timer that only exists while its own
    /// screen is on top is not a timer.
    private(set) var activeBrew: BrewTimerModel?
    /// The brew the user chose to review, shown in the same pinned slot the
    /// timer occupied.
    private(set) var reviewing: BrewSession?

    private let context: ModelContext
    private let cupboard: Cupboard
    private let profiles: BeanProfileStore

    init(context: ModelContext, cupboard: Cupboard, profiles: BeanProfileStore) {
        self.context = context
        self.cupboard = cupboard
        self.profiles = profiles
        refresh()
    }

    var isEmpty: Bool { beans.isEmpty }

    func bean(id: UUID) -> OwnedBean? { beans.first { $0.id == id } }

    func sessions(for bean: OwnedBean) -> [BrewSession] {
        sessions.filter { $0.bean?.id == bean.id }.sorted { $0.date > $1.date }
    }

    /// The advice the cupboard screen shows for a bag, from the same rule
    /// table the agent's tool reads, so the two can never disagree.
    func grindAdvice(for bean: OwnedBean) -> BrewAdvisor.GrindAdvice {
        let history = sessions(for: bean).map(BrewSessionSnapshot.init)
        guard history.contains(where: { $0.outcome != nil }) else {
            guard bean.grindSize.isAdjustable else {
                return BrewAdvisor.nextGrind(from: [], grindSize: bean.grindSize)
            }
            return BrewAdvisor.GrindAdvice(
                direction: .unknown,
                message: BrewAdvisor.startingPoint(for: bean.roastLevel)
            )
        }
        return BrewAdvisor.nextGrind(from: history, grindSize: bean.grindSize)
    }

    /// The photo is written before the bean, so a bag never persists a
    /// filename pointing at a file that failed to save. A photo that cannot be
    /// written costs the picture, not the bag.
    @discardableResult
    func add(_ draft: BagScanner.Draft, photo: UIImage? = nil) async -> OwnedBean {
        var filename: String?
        if let photo {
            do {
                filename = try await BagPhotoStore.save(photo)
            } catch {
                Log.write(.failure, "bag photo not saved: \(error)")
            }
        }

        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = BeanMatcher.best(
            name: name,
            subregion: draft.subregion,
            island: draft.island,
            in: await profiles.allProfiles()
        )
        if let match {
            Log.write(.cupboard, "linked \"\(name)\" to corpus \(match.profile.id), \(match.reason)")
        } else {
            Log.write(.cupboard, "no corpus lot matched \"\(name)\", comparison will say so")
        }

        let bean = OwnedBean(
            displayName: name,
            corpusReferenceId: match?.profile.id,
            roasterName: draft.roasterName.isEmpty ? nil : draft.roasterName,
            island: draft.island,
            subregion: draft.subregion.isEmpty ? nil : draft.subregion,
            processingMethod: draft.processingMethod,
            roastLevel: draft.roastLevel,
            roastDate: draft.roastDate,
            bagWeightGrams: draft.weightGrams,
            grindSize: draft.grindSize,
            grade: draft.grade.isEmpty ? nil : draft.grade,
            roasterNotes: draft.roasterNotes,
            bagPhotoFilename: filename,
            scanConfidence: draft.scanConfidence
        )
        context.insert(bean)
        save()
        Log.write(.cupboard, "added \"\(bean.displayName)\" provenance=\(bean.scanConfidence.rawValue) island=\(bean.island?.rawValue ?? "none") roast=\(bean.roastLevel?.rawValue ?? "none") grind=\(bean.grindSize.rawValue)")
        return bean
    }

    /// The corpus lot a bag was linked to, by name. Nil when nothing matched,
    /// which the caller is expected to say out loud rather than hide.
    func corpusName(for bean: OwnedBean) async -> String? {
        guard let id = bean.corpusReferenceId else { return nil }
        return await profiles.profile(id: id)?.name
    }

    func delete(_ bean: OwnedBean) {
        Log.write(.cupboard, "deleted \"\(bean.displayName)\" with \(bean.brewSessions.count) brews")
        // SwiftData cascades to the notes and brews but knows nothing about
        // the container, so the photos would leak.
        BagPhotoStore.delete(bean.bagPhotoFilename)
        BagPhotoStore.delete(bean.roastDatePhotoFilename)
        context.delete(bean)
        save()
    }

    /// Replaces rather than accumulates: a re-shot date stamp means the old
    /// one was wrong or unreadable, so keeping it would only be clutter.
    func attachRoastDatePhoto(_ image: UIImage, to bean: OwnedBean) async {
        do {
            let filename = try await BagPhotoStore.save(image)
            BagPhotoStore.delete(bean.roastDatePhotoFilename)
            bean.roastDatePhotoFilename = filename
            save()
            Log.write(.cupboard, "roast date photo attached to \"\(bean.displayName)\"")
        } catch {
            Log.write(.failure, "roast date photo not saved: \(error)")
            failure = "That photo could not be saved."
        }
    }

    @discardableResult
    func startBrew(bean: OwnedBean?, potSizeCups: Int, grindSetting: String, heatLevel: HeatLevel, doseGrams: Double?) -> BrewSession {
        let session = BrewSession(
            bean: bean,
            potSizeCups: potSizeCups,
            grindSetting: grindSetting,
            doseGrams: doseGrams,
            heatLevel: heatLevel
        )
        context.insert(session)
        save()
        Log.write(.brew, "started bean=\(bean?.displayName ?? "none") grind=\(grindSetting.isEmpty ? "unset" : grindSetting) pot=\(potSizeCups)cup heat=\(heatLevel.rawValue)")
        return session
    }

    /// Written as the phases happen rather than at the end, so a brew
    /// abandoned halfway still keeps the timestamps it did record.
    func record(_ session: BrewSession, firstDrip: Int? = nil, gurgle: Int? = nil, total: Int? = nil, pulledAtGurgle: Bool? = nil) {
        if let firstDrip { session.timeToFirstDripSeconds = firstDrip }
        if let gurgle { session.timeToGurgleSeconds = gurgle }
        if let total { session.totalSeconds = total }
        if let pulledAtGurgle { session.pulledAtGurgle = pulledAtGurgle }
        save()
        let marks = [firstDrip.map { "firstDrip=\($0)s" }, gurgle.map { "gurgle=\($0)s" }, total.map { "total=\($0)s" }]
        Log.write(.brew, "recorded \(marks.compactMap { $0 }.joined(separator: " "))")
    }

    /// Starting a brew pins the timer for the whole app. Cancelling an
    /// existing one first, rather than refusing, because the user asking to
    /// brew again is a clearer signal than a timer they forgot to stop.
    func beginBrew(bean: OwnedBean?, potSizeCups: Int, grindSetting: String, heatLevel: HeatLevel, doseGrams: Double?) {
        activeBrew?.stop()
        reviewing = nil
        let session = startBrew(
            bean: bean,
            potSizeCups: potSizeCups,
            grindSetting: grindSetting,
            heatLevel: heatLevel,
            doseGrams: doseGrams
        )
        activeBrew = BrewTimerModel(session: session, manager: self)
    }

    /// Unpins the timer. The session is already stored with every phase it
    /// reached, so nothing is lost by letting go of it here.
    func dismissBrew() {
        activeBrew?.stop()
        activeBrew = nil
    }

    func beginReview(of session: BrewSession) {
        Log.write(.ui, "reviewing brew from \(session.date.formatted(date: .abbreviated, time: .shortened))")
        activeBrew?.stop()
        activeBrew = nil
        reviewing = session
    }

    func endReview() {
        reviewing = nil
    }

    /// Reviewing is a separate act from brewing. The session is already
    /// stored by the time this runs; all it adds is the verdict.
    func review(_ session: BrewSession, outcome: BrewOutcome) {
        session.outcome = outcome
        save()
        if reviewing?.id == session.id { reviewing = nil }
        Log.write(.brew, "reviewed symptom=\(outcome.symptom.rawValue) grind=\(session.grindSetting.isEmpty ? "unset" : session.grindSetting)")
    }

    /// Brews nobody has said anything about yet. A nil outcome means awaiting
    /// review, not that the brew went unrecorded.
    var awaitingReview: [BrewSession] {
        sessions.filter { $0.outcome == nil }.sorted { $0.date > $1.date }
    }

    func awaitingReview(for bean: OwnedBean) -> [BrewSession] {
        awaitingReview.filter { $0.bean?.id == bean.id }
    }

    func addTastingNote(
        to bean: OwnedBean,
        acidity: IntensityLevel,
        body: IntensityLevel,
        flavors: [FlavorNote],
        rating: Int,
        brewSessionId: UUID?,
        freeformNote: String?
    ) {
        let note = TastingNote(
            perceivedAcidity: acidity,
            perceivedBody: body,
            flavorNotes: flavors,
            rating: rating,
            brewSessionId: brewSessionId,
            freeformNote: freeformNote
        )
        note.bean = bean
        context.insert(note)
        save()
        Log.write(.cupboard, "tasting note on \"\(bean.displayName)\" rating=\(rating)/5 flavours=\(flavors.map(\.rawValue).joined(separator: ",").isEmpty ? "none" : flavors.map(\.rawValue).joined(separator: ","))")
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Log.write(.failure, "cupboard save failed: \(error)")
            failure = "Could not save: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Refetch and re-push together. The agent reads snapshots rather than
    /// SwiftData objects, so a change the view can see but the tool cannot
    /// would make the agent answer about a stale cupboard.
    private func refresh() {
        beans = ((try? context.fetch(FetchDescriptor<OwnedBean>())) ?? [])
            .sorted { $0.purchaseDate > $1.purchaseDate }
        sessions = ((try? context.fetch(FetchDescriptor<BrewSession>())) ?? [])
            .sorted { $0.date > $1.date }

        let beanSnapshots = beans.map(OwnedBeanSnapshot.init)
        let sessionSnapshots = sessions.map(BrewSessionSnapshot.init)
        Log.write(.store, "pushed \(beanSnapshots.count) bags and \(sessionSnapshots.count) brews to the agent")
        Task { await cupboard.replace(beans: beanSnapshots, sessions: sessionSnapshots) }
    }
}

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

    private let context: ModelContext
    private let cupboard: Cupboard

    init(context: ModelContext, cupboard: Cupboard) {
        self.context = context
        self.cupboard = cupboard
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
            return BrewAdvisor.GrindAdvice(
                direction: .unknown,
                message: BrewAdvisor.startingPoint(for: bean.roastLevel)
            )
        }
        return BrewAdvisor.nextGrind(from: history)
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
        return add(draft, photoFilename: filename)
    }

    @discardableResult
    func add(_ draft: BagScanner.Draft, photoFilename: String? = nil) -> OwnedBean {
        let bean = OwnedBean(
            displayName: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            corpusReferenceId: nil,
            roasterName: draft.roasterName.isEmpty ? nil : draft.roasterName,
            island: draft.island,
            subregion: draft.subregion.isEmpty ? nil : draft.subregion,
            processingMethod: draft.processingMethod,
            roastLevel: draft.roastLevel,
            roastDate: draft.roastDate,
            bagWeightGrams: draft.weightGrams,
            bagPhotoFilename: photoFilename,
            scanConfidence: draft.scanConfidence
        )
        context.insert(bean)
        save()
        Log.write(.cupboard, "added \"\(bean.displayName)\" provenance=\(bean.scanConfidence.rawValue) island=\(bean.island?.rawValue ?? "none") roast=\(bean.roastLevel?.rawValue ?? "none")")
        return bean
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

    /// Reviewing is a separate act from brewing. The session is already
    /// stored by the time this runs; all it adds is the verdict.
    func review(_ session: BrewSession, outcome: BrewOutcome) {
        session.outcome = outcome
        save()
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

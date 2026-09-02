//
//  BrewViews.swift
//  Agentic
//

import Foundation
import Observation
import SwiftUI

/// Four phases, each moved on by something the user can see or hear rather
/// than by a countdown. The timestamps are the point: a first drip at 25
/// seconds and one at three minutes are different faults, and no generic guide
/// can tell them apart.
@Observable
@MainActor
final class BrewTimerModel {
    enum Phase: Int, CaseIterable {
        case heating, flowing, pullNow, finished

        var instruction: String {
            switch self {
            case .heating: "Heating. Keep it medium-low."
            case .flowing: "Flowing. Watch for the stream to turn pale."
            case .pullNow: "Off the heat now, and cool the base under the tap."
            case .finished: "Brew logged."
            }
        }

        var advanceLabel: String? {
            switch self {
            case .heating: "First drip appeared"
            case .flowing: "I hear the first gurgle"
            case .pullNow: "Done, off the heat"
            case .finished: nil
            }
        }
    }

    private(set) var elapsed = 0
    private(set) var phase = Phase.heating
    private(set) var marks: [String] = []

    private let session: BrewSession
    private let manager: CupboardManager
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(session: BrewSession, manager: CupboardManager) {
        self.session = session
        self.manager = manager
        start()
    }

    var brewSession: BrewSession { session }

    private func start() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.phase != .finished else { return }
                self.elapsed += 1
            }
        }
    }

    /// Each transition writes through to the store immediately, so a brew the
    /// user walks away from keeps the phases it did reach.
    func advance() {
        switch phase {
        case .heating:
            Log.write(.brew, "phase heating -> flowing at \(Self.clock(elapsed))")
            manager.record(session, firstDrip: elapsed)
            marks.append("First drip at \(Self.clock(elapsed)). \(BrewAdvisor.firstDripVerdict(seconds: elapsed))")
            phase = .flowing
        case .flowing:
            Log.write(.brew, "phase flowing -> pullNow at \(Self.clock(elapsed))")
            manager.record(session, gurgle: elapsed, pulledAtGurgle: true)
            marks.append("Gurgle at \(Self.clock(elapsed))")
            phase = .pullNow
        case .pullNow:
            Log.write(.brew, "phase pullNow -> finished at \(Self.clock(elapsed))")
            manager.record(session, total: elapsed)
            marks.append("Total \(Self.clock(elapsed)). \(BrewAdvisor.totalVerdict(seconds: elapsed))")
            phase = .finished
            ticker?.cancel()
        case .finished:
            break
        }
    }

    func stop() {
        Log.write(.brew, "timer stopped in phase \(phase) at \(clock)")
        ticker?.cancel()
        ticker = nil
    }

    var clock: String { Self.clock(elapsed) }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Pick the bag and the variables, then run the timer. The grind is prefilled
/// from the dial-in advice so the one variable the user is meant to move is
/// the one already in front of them.
struct BrewFlowView: View {
    let manager: CupboardManager
    @Environment(\.dismiss) private var dismiss

    @State private var beanId: UUID?
    @State private var potSizeCups = 3
    @State private var grindSetting = ""
    @State private var heatLevel = HeatLevel.mediumLow
    @State private var doseGrams: Double?
    @State private var timer: BrewTimerModel?
    @State private var reviewing: BrewSession?

    private var bean: OwnedBean? { beanId.flatMap(manager.bean(id:)) }

    var body: some View {
        NavigationStack {
            Group {
                if let reviewing {
                    BrewReviewView(manager: manager, session: reviewing) { dismiss() }
                } else if let timer {
                    BrewTimerView(timer: timer, onFinish: { dismiss() }) { session in
                        reviewing = session
                    }
                } else {
                    setup
                }
            }
            .background(Theme.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Brew").font(Theme.display).foregroundStyle(Theme.ink)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        timer?.stop()
                        dismiss()
                    }
                    .tint(Theme.inkMuted)
                }
            }
        }
    }

    private var setup: some View {
        Form {
            Section {
                Picker("Bean", selection: $beanId) {
                    Text("Not from my cupboard").tag(UUID?.none)
                    ForEach(manager.beans) { Text($0.displayName).tag(UUID?.some($0.id)) }
                }
                if let bean {
                    Text(manager.grindAdvice(for: bean).message)
                        .font(Theme.control)
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .listRowBackground(Theme.paperRaised)

            Section {
                TextField("Grind setting", text: $grindSetting)
                Picker("Pot size", selection: $potSizeCups) {
                    ForEach([1, 3, 6, 9, 12], id: \.self) { Text("\($0) cup").tag($0) }
                }
                Picker("Heat", selection: $heatLevel) {
                    ForEach(HeatLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Dose in grams", value: $doseGrams, format: .number)
                    .keyboardType(.decimalPad)
            }
            .listRowBackground(Theme.paperRaised)

            Section("Fixed for every brew") {
                ForEach(BrewAdvisor.parameters, id: \.0) { name, value in
                    VStack(alignment: .leading, spacing: Theme.xs) {
                        Text(name).font(Theme.label).foregroundStyle(Theme.inkMuted)
                        Text(value).font(Theme.control).foregroundStyle(Theme.ink)
                    }
                    .padding(.vertical, Theme.xs)
                }
            }
            .listRowBackground(Theme.paperRaised)

            Section {
                Button("Water is on, start the timer") { begin() }
                    .font(Theme.control)
                    .foregroundStyle(Theme.accent)
            }
            .listRowBackground(Theme.paperRaised)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: beanId) { prefillGrind() }
        .onAppear {
            beanId = manager.beans.first?.id
            prefillGrind()
        }
    }

    private func prefillGrind() {
        guard let bean, grindSetting.isEmpty else { return }
        grindSetting = manager.sessions(for: bean).first?.grindSetting ?? ""
    }

    private func begin() {
        let session = manager.startBrew(
            bean: bean,
            potSizeCups: potSizeCups,
            grindSetting: grindSetting,
            heatLevel: heatLevel,
            doseGrams: doseGrams
        )
        timer = BrewTimerModel(session: session, manager: manager)
    }
}

private struct BrewTimerView: View {
    let timer: BrewTimerModel
    let onFinish: () -> Void
    let onReview: (BrewSession) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.lg) {
                VStack(alignment: .leading, spacing: Theme.sm) {
                    Text(timer.clock)
                        .font(.system(size: 52, weight: .light, design: .serif))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Text(timer.phase.instruction)
                        .font(Theme.control)
                        .foregroundStyle(Theme.inkMuted)
                }

                HStack(spacing: Theme.xs) {
                    ForEach(BrewTimerModel.Phase.allCases, id: \.rawValue) { phase in
                        Capsule()
                            .fill(phase.rawValue <= timer.phase.rawValue ? Theme.accent : Theme.rule)
                            .frame(height: 3)
                    }
                }

                if let label = timer.phase.advanceLabel {
                    Button(label) { timer.advance() }
                        .font(Theme.control)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.md)
                        .background(Theme.accent, in: .capsule)
                        .foregroundStyle(Theme.paper)
                }

                if !timer.marks.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.sm) {
                        ForEach(timer.marks, id: \.self) { mark in
                            Text(mark).font(Theme.trace).foregroundStyle(Theme.inkMuted)
                        }
                    }
                }

                if timer.phase == .finished {
                    finishedActions
                }

            }
            .padding(Theme.lg)
        }
    }

    /// The brew is already stored by the time this shows. Reviewing is
    /// offered, never required: a cup you have not tasted yet is a normal
    /// state, and blocking here would either force a guess or lose the
    /// session's timings entirely.
    private var finishedActions: some View {
        VStack(alignment: .leading, spacing: Theme.md) {
            Rectangle().fill(Theme.rule).frame(height: Theme.hairline)

            Text("Logged. Taste it, then tell me how it went.")
                .font(Theme.reading)
                .foregroundStyle(Theme.ink)

            Button("Review it now") { onReview(timer.brewSession) }
                .font(Theme.control)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.md)
                .background(Theme.accent, in: .capsule)
                .foregroundStyle(Theme.paper)

            Button("Later") { onFinish() }
                .font(Theme.control)
                .foregroundStyle(Theme.inkMuted)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Two depths, because the two answers serve different things. The verdict is
/// mechanical and feeds `BrewAdvisor`, so it has to be cheap enough that
/// people actually give it: one tap. The tasting note is subjective and feeds
/// the comparison against the reference profile, so it is worth a form, but
/// only when someone wants to fill one in.
struct BrewReviewView: View {
    let manager: CupboardManager
    let session: BrewSession
    let onFinish: () -> Void

    @State private var symptom: BrewSymptom?
    @State private var addingNote = false
    @State private var rating = 3
    @State private var acidity = IntensityLevel.medium
    @State private var body_ = IntensityLevel.medium
    @State private var flavors: Set<FlavorNote> = []
    @State private var comment = ""

    var body: some View {
        Form {
            Section {
                ForEach(BrewSymptom.allCases, id: \.self) { candidate in
                    Button {
                        select(candidate)
                    } label: {
                        HStack {
                            Text(candidate.label)
                                .font(Theme.control)
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            if symptom == candidate {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            } header: {
                Text("How was it?")
            } footer: {
                Text(addingNote
                    ? "Pick one, then fill in as much of the note as you like."
                    : "Tapping a verdict saves it. That is all the dial-in needs.")
            }
            .listRowBackground(Theme.paperRaised)

            if let symptom, let remedy = BrewAdvisor.remedy(for: symptom) {
                Section("What that means") {
                    Text(remedy.cause).font(Theme.label).foregroundStyle(Theme.inkMuted)
                    Text(BrewAdvisor.advice(for: symptom, grind: grind).message)
                        .font(Theme.reading)
                        .foregroundStyle(Theme.ink)
                }
                .listRowBackground(Theme.paperRaised)
            }

            if addingNote {
                tastingNote
            } else {
                Section {
                    Button("Add a tasting note") {
                        addingNote = true
                    }
                    .font(Theme.control)
                    .foregroundStyle(Theme.accent)
                }
                .listRowBackground(Theme.paperRaised)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.paper, for: .navigationBar)
        .toolbar {
            if addingNote {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .tint(Theme.accent)
                        .disabled(symptom == nil)
                }
            }
        }
    }

    @ViewBuilder
    private var tastingNote: some View {
        Section("What you tasted") {
            ForEach(FlavorNote.allCases, id: \.self) { note in
                Button {
                    if flavors.contains(note) { flavors.remove(note) } else { flavors.insert(note) }
                } label: {
                    HStack {
                        Text(note.label).font(Theme.control).foregroundStyle(Theme.ink)
                        Spacer()
                        if flavors.contains(note) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
        .listRowBackground(Theme.paperRaised)

        Section {
            Picker("Acidity", selection: $acidity) {
                ForEach(IntensityLevel.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Body", selection: $body_) {
                ForEach(IntensityLevel.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Stepper("Rating \(rating) of 5", value: $rating, in: 1...5)
                .font(Theme.control)
            TextField("Anything else", text: $comment, axis: .vertical)
                .lineLimit(1...4)
        }
        .listRowBackground(Theme.paperRaised)
    }

    private var grind: String {
        session.grindSetting.isEmpty ? "your setting" : session.grindSetting
    }

    /// One tap is the whole interaction when no note is being written, which
    /// is what keeps the verdict cheap enough to be given at all.
    private func select(_ candidate: BrewSymptom) {
        symptom = candidate
        guard !addingNote else { return }
        manager.review(session, outcome: BrewOutcome(symptom: candidate, note: nil))
        onFinish()
    }

    private func save() {
        guard let symptom else { return }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.review(session, outcome: BrewOutcome(symptom: symptom, note: trimmed.isEmpty ? nil : trimmed))

        // Linked back to the session, so a bitter cup can be traced to the
        // grind and heat that produced it.
        if let bean = session.bean {
            manager.addTastingNote(
                to: bean,
                acidity: acidity,
                body: body_,
                flavors: Array(flavors),
                rating: rating,
                brewSessionId: session.id,
                freeformNote: trimmed.isEmpty ? nil : trimmed
            )
        }
        onFinish()
    }
}

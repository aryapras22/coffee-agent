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
            manager.record(session, firstDrip: elapsed)
            marks.append("First drip at \(Self.clock(elapsed)). \(BrewAdvisor.firstDripVerdict(seconds: elapsed))")
            phase = .flowing
        case .flowing:
            manager.record(session, gurgle: elapsed, pulledAtGurgle: true)
            marks.append("Gurgle at \(Self.clock(elapsed))")
            phase = .pullNow
        case .pullNow:
            manager.record(session, total: elapsed)
            marks.append("Total \(Self.clock(elapsed)). \(BrewAdvisor.totalVerdict(seconds: elapsed))")
            phase = .finished
            ticker?.cancel()
        case .finished:
            break
        }
    }

    func stop() {
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

    private var bean: OwnedBean? { beanId.flatMap(manager.bean(id:)) }

    var body: some View {
        NavigationStack {
            Group {
                if let timer {
                    BrewTimerView(timer: timer, manager: manager, onFinish: { dismiss() })
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
    let manager: CupboardManager
    let onFinish: () -> Void

    @State private var rating = 3
    @State private var symptom = BrewSymptom.balanced

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
                    outcomeForm
                }
            }
            .padding(Theme.lg)
        }
    }

    private var outcomeForm: some View {
        VStack(alignment: .leading, spacing: Theme.md) {
            Rectangle().fill(Theme.rule).frame(height: Theme.hairline)

            Text("How did it taste?").font(Theme.display).foregroundStyle(Theme.ink)

            Picker("Symptom", selection: $symptom) {
                ForEach(BrewSymptom.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(Theme.accent)

            Stepper("Rating \(rating) of 5", value: $rating, in: 1...5)
                .font(Theme.control)
                .foregroundStyle(Theme.ink)

            if let remedy = BrewAdvisor.remedy(for: symptom) {
                VStack(alignment: .leading, spacing: Theme.xs) {
                    Text(remedy.cause).font(Theme.label).foregroundStyle(Theme.inkMuted)
                    Text(remedy.fix).font(Theme.reading).foregroundStyle(Theme.ink)
                }
            }

            Text(BrewAdvisor.advice(for: symptom, grind: timer.brewSession.grindSetting.isEmpty ? "your setting" : timer.brewSession.grindSetting).message)
                .font(Theme.reading)
                .foregroundStyle(Theme.accent)

            Button("Save this brew") {
                manager.finish(timer.brewSession, outcome: BrewOutcome(rating: rating, symptom: symptom, note: nil))
                onFinish()
            }
            .font(Theme.control)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.md)
            .background(Theme.accent, in: .capsule)
            .foregroundStyle(Theme.paper)
        }
    }
}

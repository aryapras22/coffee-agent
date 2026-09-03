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

    var beanName: String { session.bean?.displayName ?? "Not from the cupboard" }

    var setting: String {
        let grind = session.grindSetting.isEmpty ? "grind unrecorded" : "grind \(session.grindSetting)"
        return "\(grind) · \(session.potSizeCups) cup · \(session.heatLevel.label) heat"
    }

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

// MARK: The pot

/// The pot itself, drawn rather than illustrated so it can show state. The
/// upper chamber fills as the brew progresses, which is the one thing a
/// numeric timer cannot tell you: where in the extraction you are, as opposed
/// to how long you have been standing there.
struct MokaPotView: View {
    let phase: BrewTimerModel.Phase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flicker = false
    @State private var dripping = false
    @State private var steaming = false

    /// How full the upper chamber reads, per phase. Not a measurement: a moka
    /// pot gives no way to see its own level, and pretending otherwise would
    /// be a fabricated readout.
    private var fill: CGFloat {
        switch phase {
        case .heating: 0
        case .flowing: 0.35
        case .pullNow: 0.85
        case .finished: 1
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = CGSize(width: geometry.size.width / 62, height: geometry.size.height / 76)
            // The chamber occupies y 16 to 37 of the 76 unit box, so the
            // liquid has to rise from 37 rather than from the foot of the pot.
            let chamberFloor = 37 * scale.height
            let liquid = 21 * scale.height * fill

            ZStack {
                UpperChamber()
                    .fill(Theme.accent.opacity(0.85))
                    .mask(alignment: .topLeading) {
                        Rectangle()
                            .frame(height: liquid)
                            .offset(y: chamberFloor - liquid)
                    }
                    .animation(Theme.enter, value: fill)

                PotOutline()
                    .stroke(Theme.ink, style: .init(lineWidth: 1.4, lineJoin: .round))

                if phase == .heating {
                    Flame()
                        .stroke(Theme.accent, style: .init(lineWidth: 1.4, lineCap: .round))
                        .opacity(flicker ? 0.9 : 0.3)
                        .scaleEffect(y: flicker ? 1.15 : 0.85, anchor: .bottom)
                }

                if phase == .flowing || phase == .pullNow {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 3.2 * scale.width, height: 3.2 * scale.width)
                        .position(x: 31 * scale.width, y: (dripping ? 30 : 19) * scale.height)
                        .opacity(dripping ? 0 : 0.9)
                }

                if phase == .finished {
                    Steam()
                        .stroke(Theme.inkMuted, style: .init(lineWidth: 1.2, lineCap: .round))
                        .opacity(steaming ? 0 : 0.55)
                        .offset(y: steaming ? -8 : 2)
                }
            }
        }
        .frame(width: 62, height: 76)
        .onAppear { restartAnimations() }
        .onChange(of: phase) { restartAnimations() }
        .accessibilityHidden(true)
    }

    /// Every loop is redeclared on a phase change: only one is visible at a
    /// time, and a `repeatForever` started for a phase that has passed keeps
    /// animating a view nobody can see.
    private func restartAnimations() {
        guard !reduceMotion else { return }
        switch phase {
        case .heating:
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { flicker = true }
        case .flowing, .pullNow:
            dripping = false
            withAnimation(.linear(duration: phase == .flowing ? 1.2 : 0.7).repeatForever(autoreverses: false)) {
                dripping = true
            }
        case .finished:
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { steaming = true }
        }
    }
}

/// Coordinates are in the 62 by 76 space every part of the pot is drawn in, so
/// the chambers, the handle and the flame all line up without each shape
/// carrying its own conversion.
private protocol PotGeometry: Shape {}

extension PotGeometry {
    func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + x / 62 * rect.width, y: rect.minY + y / 76 * rect.height)
    }
}

private struct UpperChamber: Shape, PotGeometry {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(17, 16, in: rect))
        path.addLine(to: point(45, 16, in: rect))
        path.addLine(to: point(43, 37, in: rect))
        path.addLine(to: point(19, 37, in: rect))
        path.closeSubpath()
        return path
    }
}

private struct PotOutline: Shape, PotGeometry {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.addPath(UpperChamber().path(in: rect))

        // The collar between the chambers, where the filter basket sits.
        path.move(to: point(19, 37, in: rect))
        path.addLine(to: point(43, 37, in: rect))
        path.addLine(to: point(41, 40, in: rect))
        path.addLine(to: point(21, 40, in: rect))
        path.closeSubpath()

        path.move(to: point(21, 40, in: rect))
        path.addLine(to: point(41, 40, in: rect))
        path.addLine(to: point(44, 66, in: rect))
        path.addLine(to: point(18, 66, in: rect))
        path.closeSubpath()

        path.move(to: point(24, 16, in: rect))
        path.addLine(to: point(27, 10, in: rect))
        path.addLine(to: point(35, 10, in: rect))
        path.addLine(to: point(38, 16, in: rect))

        return path
    }
}

private struct Flame: Shape, PotGeometry {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in [CGFloat(22), 31, 40] {
            path.move(to: point(x, 71, in: rect))
            path.addQuadCurve(to: point(x + 5, 71, in: rect), control: point(x + 2.5, 64, in: rect))
        }
        return path
    }
}

private struct Steam: Shape, PotGeometry {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in [CGFloat(26), 34] {
            path.move(to: point(x, 7, in: rect))
            path.addQuadCurve(to: point(x, 0, in: rect), control: point(x + 3.5, 3.5, in: rect))
        }
        return path
    }
}

// MARK: Pinned panels

/// The frame every pinned panel shares. Sits between the transcript and the
/// composer rather than over them, so the conversation stays readable while a
/// brew runs and the reader can still type.
struct PinnedPanel<Content: View>: View {
    let title: String
    var onClose: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sm) {
            HStack {
                Text(title)
                    .font(Theme.label)
                    .foregroundStyle(Theme.inkMuted)
                Spacer(minLength: Theme.md)
                if let onClose {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Close \(title)")
                }
            }

            content
        }
        .padding(Theme.md)
        .background(Theme.paperRaised, in: .rect(cornerRadius: Theme.bubbleRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                .stroke(Theme.rule, lineWidth: Theme.hairline)
        )
        .padding(.horizontal, Theme.md)
        .padding(.bottom, Theme.sm)
    }
}

/// Pick the bag and the variables. The grind is prefilled from the dial-in
/// advice so the one variable meant to move is already in front of the user,
/// and it disappears entirely for a bag that came pre-ground.
struct BrewSetupPanel: View {
    let manager: CupboardManager
    let onStarted: () -> Void
    let onClose: () -> Void

    @State private var beanId: UUID?
    @State private var potSizeCups = 3
    @State private var grindSetting = ""
    @State private var heatLevel = HeatLevel.mediumLow

    private var bean: OwnedBean? { beanId.flatMap(manager.bean(id:)) }

    var body: some View {
        PinnedPanel(title: "Start a brew", onClose: onClose) {
            VStack(alignment: .leading, spacing: Theme.md) {
                if manager.beans.isEmpty {
                    Text("No bags in the cupboard, so this brew will not be tied to one. Scan a bag and the timings start counting towards a dial-in.")
                        .font(Theme.label)
                        .foregroundStyle(Theme.inkMuted)
                } else {
                    HStack {
                        Text("Bean").font(Theme.label).foregroundStyle(Theme.inkMuted)
                        Spacer(minLength: Theme.sm)
                        Picker("Bean", selection: $beanId) {
                            Text("Not from my cupboard").tag(UUID?.none)
                            ForEach(manager.beans) { Text($0.displayName).tag(UUID?.some($0.id)) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(Theme.accent)
                    }
                }

                if let bean {
                    Text(manager.grindAdvice(for: bean).message)
                        .font(Theme.label)
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // A pre-ground bag has no grind to record, and offering the
                // field anyway invites a number that means nothing.
                if bean?.grindSize.isAdjustable ?? true {
                    TextField("Grind setting", text: $grindSetting)
                        .font(Theme.control)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, Theme.sm)
                        .padding(.vertical, Theme.xs + 2)
                        .background(Theme.paper, in: .rect(cornerRadius: 6))
                }

                // Labelled alongside: a menu picker outside a `Form` shows
                // only its selected value, and "Medium-low" on its own does
                // not say what it is the level of.
                HStack(spacing: Theme.md) {
                    Text("Pot").font(Theme.label).foregroundStyle(Theme.inkMuted)
                    Picker("Pot", selection: $potSizeCups) {
                        ForEach([1, 3, 6, 9, 12], id: \.self) { Text("\($0) cup").tag($0) }
                    }
                    Spacer(minLength: 0)
                    Text("Heat").font(Theme.label).foregroundStyle(Theme.inkMuted)
                    Picker("Heat", selection: $heatLevel) {
                        ForEach(HeatLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Theme.accent)
                .font(Theme.control)

                Button("Water is on, start the timer") { begin() }
                    .font(Theme.control)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.sm + 2)
                    .background(Theme.accent, in: .capsule)
                    .foregroundStyle(Theme.paper)
            }
        }
        .onAppear {
            beanId = manager.beans.first?.id
            prefillGrind()
        }
        .onChange(of: beanId) { prefillGrind() }
    }

    private func prefillGrind() {
        guard let bean, grindSetting.isEmpty else { return }
        grindSetting = manager.sessions(for: bean).first?.grindSetting ?? ""
    }

    private func begin() {
        manager.beginBrew(
            bean: bean,
            potSizeCups: potSizeCups,
            grindSetting: bean?.grindSize.isAdjustable ?? true ? grindSetting : bean?.grindSize.label ?? "",
            heatLevel: heatLevel,
            doseGrams: nil
        )
        onStarted()
    }
}

/// Stays pinned for the whole brew. Everything else in the app remains usable
/// underneath it, which is the point of pinning rather than presenting: a
/// three minute brew is exactly when someone reads about the bean.
struct BrewTimerPanel: View {
    let timer: BrewTimerModel
    let onReview: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        PinnedPanel(title: timer.phase == .finished ? "Brew logged" : "Brewing") {
            VStack(alignment: .leading, spacing: Theme.md) {
                HStack(alignment: .center, spacing: Theme.md) {
                    MokaPotView(phase: timer.phase)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(timer.beanName)
                            .font(Theme.label)
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(1)
                        Text(timer.clock)
                            .font(.system(size: 34, weight: .light, design: .serif))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                        Text(timer.phase.instruction)
                            .font(Theme.label)
                            .foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: Theme.xs) {
                    ForEach(BrewTimerModel.Phase.allCases, id: \.rawValue) { phase in
                        Capsule()
                            .fill(phase.rawValue <= timer.phase.rawValue ? Theme.accent : Theme.rule)
                            .frame(height: 3)
                    }
                }
                .animation(Theme.enter, value: timer.phase)

                if !timer.marks.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.xs) {
                        ForEach(timer.marks, id: \.self) { mark in
                            Text(mark)
                                .font(Theme.trace)
                                .foregroundStyle(Theme.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let label = timer.phase.advanceLabel {
                    Button(label) { timer.advance() }
                        .font(Theme.control)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.sm + 2)
                        .background(Theme.accent, in: .capsule)
                        .foregroundStyle(Theme.paper)
                } else {
                    // Reviewing is offered, never required: a cup you have not
                    // tasted yet is a normal state, and blocking here would
                    // force a guess into the dial-in history.
                    HStack(spacing: Theme.sm) {
                        Button("Review it now") { onReview() }
                            .font(Theme.control)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.sm + 2)
                            .background(Theme.accent, in: .capsule)
                            .foregroundStyle(Theme.paper)

                        Button("Later") { onDismiss() }
                            .font(Theme.control)
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
    }
}

/// Two depths, because the two answers serve different things. The verdict is
/// mechanical and feeds `BrewAdvisor`, so it has to be cheap enough that
/// people actually give it: one tap. The tasting note is subjective and feeds
/// the three way comparison, so it is worth a form, but only when someone
/// wants to fill one in.
struct BrewReviewPanel: View {
    let manager: CupboardManager
    let session: BrewSession
    let onFinish: (BrewSymptom) -> Void
    let onClose: () -> Void

    @State private var symptom: BrewSymptom?
    @State private var addingNote = false
    @State private var rating = 3
    @State private var acidity = IntensityLevel.medium
    @State private var perceivedBody = IntensityLevel.medium
    @State private var flavors: Set<FlavorNote> = []
    @State private var comment = ""

    var body: some View {
        PinnedPanel(title: "How was it?", onClose: onClose) {
            VStack(alignment: .leading, spacing: Theme.md) {
                Text(session.bean?.displayName ?? "That brew")
                    .font(Theme.reading)
                    .foregroundStyle(Theme.ink)

                ChipRow(items: BrewSymptom.allCases.map(\.label), selected: symptom?.label) { label in
                    guard let picked = BrewSymptom.allCases.first(where: { $0.label == label }) else { return }
                    select(picked)
                }

                if let symptom, let remedy = BrewAdvisor.remedy(for: symptom) {
                    Text(remedy.cause)
                        .font(Theme.trace)
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if addingNote {
                    tastingNote
                    Button("Save verdict and note") { save() }
                        .font(Theme.control)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.sm + 2)
                        .background(symptom == nil ? Theme.rule : Theme.accent, in: .capsule)
                        .foregroundStyle(symptom == nil ? Theme.inkMuted : Theme.paper)
                        .disabled(symptom == nil)
                } else {
                    Button("Add a full tasting note") { addingNote = true }
                        .font(Theme.control)
                        .foregroundStyle(Theme.accent)

                    Text("Tapping a verdict saves it. That is all the dial-in needs.")
                        .font(Theme.trace)
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var tastingNote: some View {
        VStack(alignment: .leading, spacing: Theme.sm) {
            Text("What did you taste?").font(Theme.label).foregroundStyle(Theme.inkMuted)

            ChipRow(items: FlavorNote.allCases.map(\.label), selectedSet: Set(flavors.map(\.label))) { label in
                guard let note = FlavorNote.allCases.first(where: { $0.label == label }) else { return }
                if flavors.contains(note) { flavors.remove(note) } else { flavors.insert(note) }
            }

            HStack(spacing: Theme.md) {
                Text("Acidity").font(Theme.label).foregroundStyle(Theme.inkMuted)
                Picker("Acidity", selection: $acidity) {
                    ForEach(IntensityLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Spacer(minLength: 0)
                Text("Body").font(Theme.label).foregroundStyle(Theme.inkMuted)
                Picker("Body", selection: $perceivedBody) {
                    ForEach(IntensityLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.accent)
            .font(Theme.control)

            Stepper("Rating \(rating) of 5", value: $rating, in: 1...5)
                .font(Theme.control)
                .foregroundStyle(Theme.ink)

            TextField("Anything else", text: $comment, axis: .vertical)
                .font(Theme.control)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .padding(.horizontal, Theme.sm)
                .padding(.vertical, Theme.xs + 2)
                .background(Theme.paper, in: .rect(cornerRadius: 6))
        }
    }

    /// One tap is the whole interaction when no note is being written, which
    /// is what keeps the verdict cheap enough to be given at all.
    private func select(_ candidate: BrewSymptom) {
        symptom = candidate
        guard !addingNote else { return }
        manager.review(session, outcome: BrewOutcome(symptom: candidate, note: nil))
        onFinish(candidate)
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
                body: perceivedBody,
                flavors: Array(flavors),
                rating: rating,
                brewSessionId: session.id,
                freeformNote: trimmed.isEmpty ? nil : trimmed
            )
        }
        onFinish(symptom)
    }
}

/// Wrapping row of tappable chips, used wherever a choice is short enough to
/// show all of at once rather than hiding behind a picker.
struct ChipRow: View {
    let items: [String]
    var selected: String?
    var selectedSet: Set<String> = []
    let action: (String) -> Void

    var body: some View {
        FlowLayout(spacing: Theme.xs) {
            ForEach(items, id: \.self) { item in
                let isOn = selected == item || selectedSet.contains(item)
                Button {
                    action(item)
                } label: {
                    Text(item)
                        .font(Theme.label)
                        .foregroundStyle(isOn ? Theme.paper : Theme.ink)
                        .padding(.horizontal, Theme.sm + 2)
                        .padding(.vertical, Theme.xs + 2)
                        .background(isOn ? Theme.accent : Theme.paper, in: .capsule)
                        .overlay(Capsule().stroke(isOn ? Theme.accent : Theme.rule, lineWidth: Theme.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}

/// Wraps its subviews onto as many rows as they need. `HStack` would clip and
/// a `LazyVGrid` would force equal columns, which reads badly for chips whose
/// widths are the words in them.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width limit: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > limit, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let last = rows.count - 1
            rows[last].width = rows[last].indices.isEmpty ? size.width : rows[last].width + spacing + size.width
            rows[last].height = max(rows[last].height, size.height)
            rows[last].indices.append(index)
        }
        return rows
    }
}

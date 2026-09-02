//
//  ContentView.swift
//  Agentic
//
//  Created by Arya on 24/08/26.
//

import Foundation
import FoundationModels
import MapKit
import SwiftData
import SwiftUI

/// A view-layer projection over persisted `ChatMessage`s, plus the two things
/// the store deliberately does not persist: a `.failure` role and the current
/// run's tool trace.
struct DisplayMessage: Identifiable {
    enum Role {
        case user
        case agent
        case failure
    }

    let id: UUID
    let role: Role
    let text: String
    var steps: [AgentStep] = []
    var places: [MappedPlace] = []
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: ChatManager?
    @State private var cupboard: CupboardManager?
    @State private var path: [ChatSession] = []
    @State private var sheet: Workbench?
    @FocusState private var isComposerFocused: Bool

    /// The three things the agent cannot do for you: hold a camera, run a
    /// live timer, and cover a card before you answer it.
    enum Workbench: String, Identifiable {
        case cupboard, brew, learn

        var id: String { rawValue }
    }

    private static let starters = [
        "Recommend me a bean",
        "What do I have?",
        "My coffee tastes bitter",
    ]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    rooms(for: model)
                } else {
                    ProgressView()
                }
            }
            .background(Theme.paper)
            // Feeds the back button's label from the chat screen; the styled
            // principal item is what actually shows in the bar.
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: ChatSession.self) { _ in
                if let model {
                    chat(for: model)
                        .background(Theme.paper)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(Theme.paper, for: .navigationBar)
                        .toolbarBackground(.visible, for: .navigationBar)
                }
            }
        }
        .task {
            if model == nil, let agent = try? CoffeeAgent() {
                model = ChatManager(context: modelContext, agent: agent)
                cupboard = CupboardManager(context: modelContext, cupboard: agent.cupboard)
            }
            await model?.prepareIndex()
        }
        .sheet(item: $sheet) { destination in
            if let cupboard {
                switch destination {
                case .cupboard: CupboardView(manager: cupboard)
                case .brew: BrewFlowView(manager: cupboard)
                case .learn: LearnView()
                }
            }
        }
    }

    /// The saved sessions, as rooms to open. Reads `ChatManager`'s existing
    /// session list rather than fetching its own, so the row marked current
    /// and the transcript behind it can never disagree.
    private func rooms(for model: ChatManager) -> some View {
        List {
            ForEach(model.sessions) { session in
                Button {
                    open(session, on: model)
                } label: {
                    roomRow(for: session, current: session.id == model.chatSession.id)
                }
                .listRowBackground(Theme.paper)
            }
            .onDelete { offsets in
                offsets.map { model.sessions[$0] }.forEach(model.delete)
            }
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Chats")
                    .font(Theme.display)
                    .foregroundStyle(Theme.ink)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.newChat()
                    path.append(model.chatSession)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .tint(Theme.accent)
                .disabled(!model.canStartNewChat)
                .accessibilityLabel("New chat")
            }
        }
    }

    /// Switching the session before the push, rather than from the pushed
    /// view's `task`, keeps the previous room's transcript from showing for
    /// a frame under the new room's title.
    private func open(_ session: ChatSession, on model: ChatManager) {
        model.select(session)
        path.append(session)
    }

    private func roomRow(for session: ChatSession, current: Bool) -> some View {
        HStack(spacing: Theme.md) {
            VStack(alignment: .leading, spacing: Theme.xs) {
                Text(session.title)
                    .font(Theme.reading)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                Text(roomDetail(for: session))
                    .font(Theme.label)
                    .foregroundStyle(Theme.inkMuted)
            }

            Spacer(minLength: 0)

            if current {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(Theme.inkMuted)
        }
        .padding(.vertical, Theme.xs)
        .contentShape(.rect)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    /// A summarised room says so, because its earlier turns are no longer
    /// verbatim in the context the agent answers from.
    private func roomDetail(for session: ChatSession) -> String {
        var parts = [session.lastActivity.formatted(.relative(presentation: .named))]
        parts.append("\(session.messages.count) messages")
        if session.summary != nil {
            parts.append("summarised")
        }
        return parts.joined(separator: " · ")
    }

    private func chat(for model: ChatManager) -> some View {
        VStack(spacing: 0) {
            transcript(for: model)
            composer(for: model)
        }
        // Leaving the room has to take the keyboard with it; the field is
        // gone by then, but the responder is not always released on its own.
        .onDisappear { isComposerFocused = false }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Beans")
                    .font(Theme.display)
                    .foregroundStyle(Theme.ink)
            }

            ToolbarItem(placement: .topBarTrailing) {
                workbenchMenu
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.newChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .tint(Theme.accent)
                .disabled(!model.canStartNewChat)
                .accessibilityLabel("New chat")
            }
        }
    }

    private var workbenchMenu: some View {
        Menu {
            Button("Start a brew", systemImage: "timer") { open(.brew) }
            Button("My cupboard", systemImage: "archivebox") { open(.cupboard) }
            Button("Flashcards", systemImage: "rectangle.on.rectangle") { open(.learn) }
        } label: {
            Image(systemName: "cup.and.saucer")
        }
        .tint(Theme.accent)
        .accessibilityLabel("Brew, cupboard and flashcards")
    }

    private func open(_ destination: Workbench) {
        Log.write(.ui, "opened \(destination.rawValue)")
        sheet = destination
    }

    private func transcript(for model: ChatManager) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.lg) {
                    if let reason = model.unavailableReason {
                        Text(reason)
                            .font(Theme.trace)
                            .foregroundStyle(Theme.danger)
                            .padding(Theme.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.paperRaised, in: .rect(cornerRadius: Theme.bubbleRadius))
                    }

                    if model.displayMessages.isEmpty {
                        emptyState(for: model)
                    }

                    ForEach(model.displayMessages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    }

                    if model.isResponding {
                        thinking(for: model)
                    }

                    // One anchor for every scroll, so the target does not move
                    // between the last message, the thinking row, and the steps
                    // arriving underneath it.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding(Theme.lg)
                .animation(Theme.enter, value: model.displayMessages.count)
                .animation(Theme.enter, value: model.liveSteps.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.displayMessages.count) { scrollToLatest(proxy) }
            .onChange(of: model.isResponding) { scrollToLatest(proxy) }
            .onChange(of: model.liveSteps.count) { scrollToLatest(proxy) }
        }
    }

    private func emptyState(for model: ChatManager) -> some View {
        VStack(alignment: .leading, spacing: Theme.xl) {
            VStack(alignment: .leading, spacing: Theme.sm) {
                Text("\(model.beanCount.formatted()) Indonesian lots, indexed.")
                    .font(Theme.display)
                    .foregroundStyle(Theme.ink)
                Text("Moka pot only. The agent searches the corpus and your own bags before it answers, and shows you what it looked at.")
                    .font(Theme.control)
                    .foregroundStyle(Theme.inkMuted)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.starters, id: \.self) { starter in
                    Rectangle()
                        .fill(Theme.rule)
                        .frame(height: Theme.hairline)

                    Button {
                        Task { await model.send(starter) }
                    } label: {
                        HStack {
                            Text(starter)
                                .font(Theme.reading)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: Theme.md)
                            Image(systemName: "arrow.up.left")
                                .font(.caption)
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.vertical, Theme.md)
                    }
                    .buttonStyle(PressScale())
                    .disabled(model.isResponding)
                }
            }
        }
    }

    /// Carries the same ruled margin as a finished agent turn, so the steps
    /// arriving here sit where the answer they belong to will land.
    private func thinking(for model: ChatManager) -> some View {
        HStack(alignment: .top, spacing: Theme.md) {
            Rectangle()
                .fill(Theme.rule)
                .frame(width: Theme.accentRule)

            VStack(alignment: .leading, spacing: Theme.sm) {
                HStack(spacing: Theme.sm) {
                    Text("thinking")
                        .font(Theme.trace)
                        .foregroundStyle(Theme.inkMuted)
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.inkMuted)
                }

                if !model.liveSteps.isEmpty {
                    StepTrace(steps: model.liveSteps)
                }
            }

            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func composer(for model: ChatManager) -> some View {
        VStack(alignment: .trailing, spacing: Theme.sm) {
            memoryGauge(for: model)

            HStack(alignment: .bottom, spacing: Theme.sm) {
                TextField("Ask about beans, brewing, or your bags", text: Binding(get: { model.draft }, set: { model.draft = $0 }), axis: .vertical)
                    .font(Theme.control)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused($isComposerFocused)
                    .padding(.horizontal, Theme.md)
                    .padding(.vertical, Theme.sm + 2)
                    .background(Theme.paper, in: .capsule)
                    .overlay(Capsule().stroke(Theme.rule, lineWidth: Theme.hairline))

                SendButton(isResponding: model.isResponding, isEnabled: model.canSend) {
                    Task { await model.send() }
                }
            }
        }
        .padding(Theme.md)
        .background(Theme.paper)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.rule)
                .frame(height: Theme.hairline)
        }
    }

    /// How much of the context window the conversation occupies. Called memory
    /// rather than tokens because what it tells the reader is when the agent
    /// starts compacting, not how the model bills.
    private func memoryGauge(for model: ChatManager) -> some View {
        let usage = min(model.contextUsage, 1)
        let isCompacting = usage >= ChatManager.compactionThreshold

        return HStack(spacing: Theme.sm) {
            Text("memory \(usage.formatted(.percent.precision(.fractionLength(0))))")
                .font(Theme.trace)
                .foregroundStyle(isCompacting ? Theme.accent : Theme.inkMuted)

            Capsule()
                .fill(Theme.rule)
                .frame(width: Self.gaugeWidth, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(isCompacting ? Theme.accent : Theme.inkMuted)
                        .frame(width: Self.gaugeWidth * usage)
                }
        }
        .animation(Theme.enter, value: usage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory used")
        .accessibilityValue(usage.formatted(.percent.precision(.fractionLength(0))))
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        withAnimation(Theme.enter) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }

    private static let bottomID = "bottom"
    private static let gaugeWidth: CGFloat = 44
}

private struct MessageRow: View {
    let message: DisplayMessage

    @ViewBuilder
    var body: some View {
        switch message.role {
        case .user:
            userTurn
        case .agent:
            agentTurn(rule: Theme.accent, caption: nil)
        case .failure:
            agentTurn(rule: Theme.danger, caption: "Failed")
        }
    }

    /// The user gets a bubble and the agent gets a ruled margin, so the two
    /// roles read differently rather than as mirrored speech balloons.
    private var userTurn: some View {
        HStack {
            Spacer(minLength: Theme.xl)
            Text(message.text)
                .font(Theme.control)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, Theme.md)
                .padding(.vertical, Theme.sm)
                .background(Theme.paperRaised, in: .rect(cornerRadius: Theme.bubbleRadius))
        }
    }

    /// The model answers in markdown, so the raw string would show its own
    /// asterisks. Inline-only parsing keeps the line breaks the reply was
    /// written with; full parsing folds every one of them into a paragraph.
    private static func formatted(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func agentTurn(rule: Color, caption: String?) -> some View {
        HStack(alignment: .top, spacing: Theme.md) {
            Rectangle()
                .fill(rule)
                .frame(width: Theme.accentRule)

            VStack(alignment: .leading, spacing: Theme.sm) {
                if let caption {
                    Text(caption)
                        .font(Theme.label)
                        .foregroundStyle(rule)
                }

                Text(message.role == .failure ? AttributedString(message.text) : Self.formatted(message.text))
                    .font(Theme.reading)
                    .foregroundStyle(message.role == .failure ? Theme.inkMuted : Theme.ink)
                    .textSelection(.enabled)

                if !message.places.isEmpty {
                    MapPreview(places: message.places)
                }

                if !message.steps.isEmpty {
                    StepTrace(steps: message.steps)
                }
            }

            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Every cafe the turn found, on one map. Non-interactive on purpose: a
/// pannable map inside a scrolling transcript fights the scroll, and the
/// gesture the reader wants here is "show me this properly", which is Maps.
private struct MapPreview: View {
    let places: [MappedPlace]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.xs) {
            if let region = Self.region(covering: places) {
                Map(initialPosition: .region(region), interactionModes: []) {
                    ForEach(places) { place in
                        Marker(place.name, systemImage: "cup.and.saucer.fill", coordinate: place.coordinate)
                            .tint(Theme.accent)
                    }
                }
                .frame(height: 180)
                .clipShape(.rect(cornerRadius: Theme.bubbleRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                        .stroke(Theme.rule, lineWidth: Theme.hairline)
                )
                .allowsHitTesting(false)
            }

            Text("\(places.count) nearby · tap to open in Maps")
                .font(Theme.label)
                .foregroundStyle(Theme.inkMuted)
        }
        .contentShape(.rect)
        .onTapGesture { openInMaps() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(places.count) cafes nearby")
        .accessibilityHint("Opens them in Maps")
        .accessibilityAddTraits(.isButton)
    }

    /// Maps decides the framing itself once it has more than one item, so the
    /// pins arrive already fitted rather than centred on an arbitrary one.
    private func openInMaps() {
        let items = places.map { place -> MKMapItem in
            let item = MKMapItem(
                location: CLLocation(latitude: place.latitude, longitude: place.longitude),
                address: MKAddress(fullAddress: place.address, shortAddress: nil)
            )
            item.name = place.name
            return item
        }
        MKMapItem.openMaps(with: items, launchOptions: nil)
    }

    /// Nil for an empty list rather than a region over nowhere. The 40% margin
    /// keeps a pin off the edge, and the floor stops a single result from
    /// zooming to street level.
    private static func region(covering places: [MappedPlace]) -> MKCoordinateRegion? {
        let latitudes = places.map(\.latitude)
        let longitudes = places.map(\.longitude)
        guard
            let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
            let minLongitude = longitudes.min(), let maxLongitude = longitudes.max()
        else { return nil }

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 1.4, 0.006),
                longitudeDelta: max((maxLongitude - minLongitude) * 1.4, 0.006)
            )
        )
    }
}

private struct StepTrace: View {
    let steps: [AgentStep]

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.md) {
            Button {
                withAnimation(Theme.enter) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.xs) {
                    Text("\(steps.count) steps")
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .font(Theme.label)
                .foregroundStyle(Theme.inkMuted)
            }
            .buttonStyle(PressScale())

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.md) {
                    ForEach(steps) { step in
                        VStack(alignment: .leading, spacing: Theme.xs) {
                            HStack(spacing: Theme.xs) {
                                Image(systemName: icon(for: step))
                                    .font(.caption2)
                                Text(step.tool)
                            }
                            .font(Theme.label)
                            .foregroundStyle(Theme.accent)

                            Text(detail(of: step))
                                .font(Theme.trace)
                                .foregroundStyle(Theme.inkMuted)
                                .textSelection(.enabled)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, Theme.md)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.rule)
                        .frame(width: Theme.hairline)
                }
            }
        }
        .padding(.top, Theme.xs)
    }

    private func icon(for step: AgentStep) -> String {
        switch step.detail {
        case .call: "arrow.up.right"
        case .output: "arrow.down.left"
        }
    }

    private func detail(of step: AgentStep) -> String {
        switch step.detail {
        case .call(let arguments): arguments
        case .output(let result): result
        }
    }
}

private struct SendButton: View {
    let isResponding: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isEnabled ? Theme.accent : Theme.rule)

                if isResponding {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.inkMuted)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isEnabled ? Theme.paper : Theme.inkMuted)
                }
            }
            .frame(width: 34, height: 34)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .disabled(!isEnabled)
        .accessibilityLabel("Send")
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

//#Preview {
//    ContentView()
//}

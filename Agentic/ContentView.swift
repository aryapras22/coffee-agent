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
    var cards: [ThreadCard] = []
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: ChatManager?
    @State private var cupboard: CupboardManager?
    @State private var path: [ChatSession] = []
    @State private var sheet: Workbench?
    /// A panel the user opened, as opposed to one the cupboard is already
    /// running. Resolved after the live brew and the open review, so starting
    /// a brew replaces the setup panel with the timer rather than stacking.
    @State private var panel: Panel?
    @State private var pendingBag: PendingBag?
    @State private var bagScan: BagScan?
    @State private var showingCamera = false
    @State private var pendingCapture: UIImage?
    @FocusState private var isComposerFocused: Bool

    /// The one screen still worth covering the chat with: a list you delete
    /// rows from. Everything else the agent used to hand off to a sheet now
    /// happens in the conversation.
    enum Workbench: String, Identifiable {
        case cupboard, memory

        var id: String { rawValue }
    }

    enum Panel {
        case brewSetup
    }

    /// A scanned or blank bag waiting to be checked.
    struct PendingBag {
        /// Identity for the card, so a second bag gets its own field state
        /// instead of inheriting the previous one's.
        let id = UUID()
        var draft: BagScanner.Draft
        var ocrText: String?
        var photo: UIImage?
    }

    /// A scan in progress. Held here rather than on the card because the
    /// camera cover is attached to the chat, and a card in a lazy stack can be
    /// torn down under it.
    struct BagScan {
        var stage: BagScanCard.Stage = .capture
        var image: UIImage?
        var failure: String?
    }

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
                cupboard = CupboardManager(
                    context: modelContext,
                    cupboard: agent.cupboard,
                    profiles: agent.store
                )
            }
            await model?.prepareIndex()
        }
        .sheet(item: $sheet) { destination in
            if let cupboard {
                switch destination {
                case .cupboard:
                    CupboardView(manager: cupboard)
                case .memory:
                    if let model {
                        MemoryView(model: model)
                    }
                }
            }
        }
    }

    /// The app speaking, not the model. Everything here is read back off the
    /// bag that was just written, so the one thing a scan most often gets
    /// wrong, a silent mismatch against the corpus, is stated rather than
    /// assumed.
    private func announce(_ bean: OwnedBean, cupboard: CupboardManager) async {
        guard let model else { return }
        let link = await cupboard.corpusName(for: bean)

        var sentences = ["Saved \(bean.displayName)."]
        sentences.append(link.map { "Linked to \($0) in the corpus." }
            ?? "Nothing in the corpus matched it, so there is no reference profile to compare against.")
        if !bean.grindSize.isAdjustable {
            sentences.append("It is pre-ground \(bean.grindSize.label.lowercased()), so the dial-in will work on heat and timing rather than grind.")
        }
        if bean.roastDate == nil {
            sentences.append("No roast date, so freshness will stay unknown until you add one.")
        }

        model.post(
            sentences.joined(separator: " "),
            cards: [.owned(OwnedCard(OwnedBeanSnapshot(bean), corpusLink: link))]
        )
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
                    clearComposingSurfaces()
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
        clearComposingSurfaces()
        path.append(session)
    }

    /// A half-filled bag form belongs to the conversation it was opened in.
    /// Leaving it standing through a new chat makes it look like the fresh
    /// thread already has something in it.
    ///
    /// A running brew deliberately survives: the timer is app-wide, and the
    /// pot does not stop because you opened another chat.
    private func clearComposingSurfaces() {
        if pendingBag != nil || bagScan != nil || panel != nil {
            Log.write(.ui, "cleared the bag and brew setup panels for a different chat")
        }
        pendingBag = nil
        bagScan = nil
        panel = nil
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
            if let cupboard {
                pinned(for: model, cupboard: cupboard)
            }
            replies(for: model)
            composer(for: model)
        }
        // Attached here, not to the card: the cover has to outlive whatever
        // presented it, and reading waits for the camera to finish dismissing
        // so the confirm card is not racing a cover still on screen.
        .fullScreenCover(isPresented: $showingCamera, onDismiss: readPendingCapture) {
            CameraPicker { captured in
                bagScan?.image = captured
                pendingCapture = captured
            }
            .ignoresSafeArea()
        }
        .onChange(of: cupboard?.activeBrew?.phase) { _, phase in
            guard phase == .finished, let cupboard, let timer = cupboard.activeBrew else { return }
            model.post(
                "Logged. \(timer.marks.joined(separator: " ")) The coffee is too hot to judge right now, so I have left the review open."
            )
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
                    clearComposingSurfaces()
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
            Button("Start a brew", systemImage: "timer") {
                Log.write(.ui, "opened the brew setup panel")
                panel = .brewSetup
            }
            Button("Scan a bag", systemImage: "camera") { startScan() }
            Button("Add a bag by hand", systemImage: "square.and.pencil") { enterBagByHand() }
            Button("My cupboard", systemImage: "archivebox") { open(.cupboard) }
        } label: {
            Image(systemName: "cup.and.saucer")
        }
        .tint(Theme.accent)
        .accessibilityLabel("Brew, scan and cupboard")
    }

    private func open(_ destination: Workbench) {
        Log.write(.ui, "opened \(destination.rawValue)")
        sheet = destination
    }

    /// One slot, resolved in order of what is already happening: a review the
    /// user opened, then a brew already running, then a setup they asked for.
    /// Sitting between the transcript and the composer rather than over them
    /// is what lets a three minute brew run while the conversation carries on.
    @ViewBuilder
    private func pinned(for model: ChatManager, cupboard: CupboardManager) -> some View {
        if let session = cupboard.reviewing {
            BrewReviewPanel(
                manager: cupboard,
                session: session,
                onFinish: { symptom in announce(symptom, for: session, cupboard: cupboard, on: model) },
                onClose: { cupboard.endReview() }
            )
        } else if let timer = cupboard.activeBrew {
            BrewTimerPanel(
                timer: timer,
                onReview: { cupboard.beginReview(of: timer.brewSession) },
                onDismiss: { cupboard.dismissBrew() }
            )
        } else if panel == .brewSetup {
            BrewSetupPanel(
                manager: cupboard,
                onStarted: { panel = nil },
                onClose: { panel = nil }
            )
        }
    }

    private func startScan() {
        Log.write(.ui, "opened the scan card in the thread")
        pendingBag = nil
        bagScan = BagScan()
    }

    private func enterBagByHand() {
        Log.write(.ui, "opened a blank bag form in the thread")
        bagScan = nil
        pendingBag = PendingBag(draft: BagScanner.Draft())
    }

    private func readPendingCapture() {
        guard let pendingCapture else { return }
        self.pendingCapture = nil
        Task { await read(pendingCapture) }
    }

    /// OCR, then extraction, then hand off to the confirm card. A failed read
    /// leaves the scan card standing rather than ending the flow, so a bad
    /// photo does not cost the user the bag.
    private func read(_ captured: UIImage) async {
        guard let cgImage = captured.cgImage else {
            bagScan?.failure = "That image could not be read."
            return
        }

        Log.write(.scan, "processing a \(Int(captured.size.width))x\(Int(captured.size.height)) capture")
        bagScan = BagScan(stage: .reading, image: captured)
        do {
            let text = try await BagScanner.readText(from: cgImage)
            bagScan?.stage = .extracting
            // Never throws: an Indonesian label the model refuses still comes
            // back as a draft filled from the label vocabulary alone.
            let draft = await BagScanner.draft(fromOCR: text)

            // Vision has read it, so nothing downstream needs the full frame.
            // Holding one in view state while the user checks a dozen fields
            // is tens of megabytes for a picture shown at 110 points.
            let preview = await BagPhotoStore.previewSized(captured)
            Log.write(.scan, "ready for confirmation, preview \(Int(preview.size.width))x\(Int(preview.size.height))")
            bagScan = nil
            pendingBag = PendingBag(draft: draft, ocrText: text, photo: preview)
        } catch {
            Log.write(.failure, "scan failed: \(error)")
            bagScan = BagScan(
                stage: .capture,
                image: captured,
                failure: "\(error.localizedDescription) You can still enter the bag by hand."
            )
        }
    }

    /// The deterministic dial-in, verbatim. The rule table is what makes the
    /// answer reproducible, so the app quotes it rather than asking the model
    /// to paraphrase a fixed string.
    private func announce(
        _ symptom: BrewSymptom,
        for session: BrewSession,
        cupboard: CupboardManager,
        on model: ChatManager
    ) {
        let grindSize = session.bean?.grindSize ?? .wholeBean
        let advice = BrewAdvisor.advice(
            for: symptom,
            grind: session.grindSetting.isEmpty ? "your setting" : session.grindSetting,
            grindSize: grindSize
        )
        model.post("Noted as \(symptom.label.lowercased()). \(advice.message)")
    }

    /// Tappable answers to whatever the agent last said. When it asked a
    /// question through `offerChoices` these are its own options; otherwise
    /// they follow from the cards on screen.
    @ViewBuilder
    private func replies(for model: ChatManager) -> some View {
        let items = model.quickReplies
        if !items.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: Theme.sm) {
                    ForEach(items, id: \.self) { reply in
                        Button {
                            send(reply, on: model)
                        } label: {
                            Text(reply)
                                .font(Theme.control)
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, Theme.md)
                                .padding(.vertical, Theme.sm)
                                .background(Theme.paper, in: .capsule)
                                .overlay(Capsule().stroke(Theme.rule, lineWidth: Theme.hairline))
                        }
                        .buttonStyle(PressScale())
                    }
                }
                .padding(.horizontal, Theme.md)
                .padding(.bottom, Theme.sm)
            }
            .scrollIndicators(.hidden)
            .frame(height: 48)
        }
    }

    /// A chip naming something the app does rather than something to ask about
    /// opens that instead of sending it as a question, so "Scan a bag" reaches
    /// the camera rather than a reply explaining how to.
    private func send(_ reply: String, on model: ChatManager) {
        switch reply {
        case "Scan a bag":
            startScan()
        case "Start brewing":
            panel = .brewSetup
        case "Review my brews":
            guard let session = cupboard?.awaitingReview.first else { break }
            cupboard?.beginReview(of: session)
        default:
            Task { await model.send(reply) }
        }
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

                    if let scan = bagScan {
                        BagScanCard(
                            stage: scan.stage,
                            image: scan.image,
                            failure: scan.failure,
                            onTakePhoto: { showingCamera = true },
                            onImage: { captured in Task { await read(captured) } },
                            onEnterByHand: { enterBagByHand() },
                            onCancel: { bagScan = nil }
                        )
                        .id(Self.scanID)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    }

                    if let pending = pendingBag, let cupboard {
                        BagConfirmCard(
                            manager: cupboard,
                            draft: pending.draft,
                            ocrText: pending.ocrText,
                            photo: pending.photo
                        ) { saved in
                            pendingBag = nil
                            guard let saved else { return }
                            Task { await announce(saved, cupboard: cupboard) }
                        }
                        // Identified by the bag it started from: stable while
                        // editing so the keyboard is not dropped on every
                        // keystroke, new when a different bag arrives.
                        .id(pending.id)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    }

                    // One anchor for every scroll, so the target does not move
                    // between the last message, the thinking row, and the steps
                    // arriving underneath it.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding(Theme.lg)
                // On the container, not the scroll view: an ancestor tap
                // gesture yields to any button, field or card that wants the
                // touch, so this only fires on the gaps between them.
                .contentShape(.rect)
                .onTapGesture { dismissKeyboard() }
                .animation(Theme.enter, value: model.displayMessages.count)
                .animation(Theme.enter, value: model.liveSteps.count)
                .animation(Theme.enter, value: pendingBag != nil)
                .animation(Theme.enter, value: bagScan?.stage)
            }
            .scrollDismissesKeyboard(.interactively)
            // Behind the content, so a tap that a button, a field or a card
            // already consumed never reaches it. `.interactively` only
            // dismisses on a drag, which left no way to close the keyboard by
            // tapping the conversation.
            .background {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { dismissKeyboard() }
            }
            .onChange(of: model.displayMessages.count) { scrollToLatest(proxy) }
            .onChange(of: model.isResponding) { scrollToLatest(proxy) }
            .onChange(of: model.liveSteps.count) { scrollToLatest(proxy) }
            .onChange(of: pendingBag != nil) { scrollToLatest(proxy) }
            .onChange(of: bagScan?.stage) { scrollToLatest(proxy) }
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
                ForEach(QuickReplies.opening, id: \.self) { starter in
                    Rectangle()
                        .fill(Theme.rule)
                        .frame(height: Theme.hairline)

                    Button {
                        send(starter, on: model)
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

        return Button {
            open(.memory)
        } label: {
            HStack(spacing: Theme.sm) {
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
            .padding(.horizontal, Theme.sm)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(PressScale())
        .animation(Theme.enter, value: usage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory used")
        .accessibilityValue(usage.formatted(.percent.precision(.fractionLength(0))))
        .accessibilityHint("Shows what the agent is currently carrying")
        .accessibilityAddTraits(.isButton)
    }

    /// The composer, the confirm card and both brew panels each own their own
    /// text field, so "close the keyboard" cannot be expressed as clearing one
    /// `FocusState`. Resigning the first responder covers whichever is up.
    private func dismissKeyboard() {
        isComposerFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        withAnimation(Theme.enter) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }

    private static let bottomID = "bottom"
    private static let scanID = "scan-bag"
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

                ForEach(message.cards) { card in
                    ThreadCardView(card: card)
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

/// What the gauge is a percentage of. The number alone says how full the
/// window is; this says with what, which is the part that changes what to do
/// about it. A window mostly full of tool results is fixed by asking a
/// narrower question, one full of conversation by starting a new chat.
private struct MemoryView: View {
    let model: ChatManager
    @Environment(\.dismiss) private var dismiss
    @State private var report: ContextReport?

    var body: some View {
        NavigationStack {
            Group {
                if let report {
                    content(report)
                } else {
                    ProgressView().tint(Theme.inkMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Memory").font(Theme.display).foregroundStyle(Theme.ink)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.tint(Theme.accent)
                }
            }
        }
        .task { report = await model.contextReport() }
    }

    private func content(_ report: ContextReport) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.sm) {
                    Text(report.usage.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 44, weight: .light, design: .serif))
                        .foregroundStyle(report.usage >= ChatManager.compactionThreshold ? Theme.accent : Theme.ink)

                    Text("\(report.usedTokens.formatted()) of \(report.budget.formatted()) tokens")
                        .font(Theme.control)
                        .foregroundStyle(Theme.inkMuted)

                    Text("\(report.fixedOverhead.formatted()) of those are spent before you say anything, on the agent's instructions and its tool definitions. That leaves about \(report.roomForConversation.formatted()) for the conversation itself.")
                        .font(Theme.trace)
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(report.usage >= ChatManager.compactionThreshold
                        ? "Over the threshold, so the earliest turns are being summarised away after each reply."
                        : "At \(ChatManager.compactionThreshold.formatted(.percent.precision(.fractionLength(0)))) the earliest turns get summarised to make room.")
                        .font(Theme.trace)
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Theme.xs)
            }
            .listRowBackground(Theme.paper)

            Section {
                ForEach(report.sections) { section in
                    row(section, largest: report.sections.first?.tokens ?? 1)
                }
            } header: {
                Text("What is in there")
            } footer: {
                Text("Counted one kind at a time, so these do not add up to the total: each count carries a little of the transcript's own framing.")
            }
            .listRowBackground(Theme.paper)

            if let summary = report.summary {
                Section {
                    Text(summary)
                        .font(Theme.reading)
                        .foregroundStyle(Theme.ink)
                } header: {
                    Text("Standing in for earlier turns")
                } footer: {
                    Text("Those turns are no longer held word for word. The last \(report.recentMessagesReplayed) messages are replayed verbatim alongside this.")
                }
                .listRowBackground(Theme.paper)
            }
        }
        .listStyle(.plain)
    }

    private func row(_ section: ContextReport.Section, largest: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.xs) {
            HStack {
                Text(section.id).font(Theme.control).foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.md)
                Text("\(section.tokens.formatted()) tokens")
                    .font(Theme.label)
                    .foregroundStyle(Theme.inkMuted)
            }

            Capsule()
                .fill(Theme.rule)
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: geometry.size.width * share(section.tokens, of: largest))
                    }
                }

            Text(section.entries == 1 ? "1 entry" : "\(section.entries) entries")
                .font(Theme.trace)
                .foregroundStyle(Theme.inkMuted)
        }
        .padding(.vertical, Theme.xs)
    }

    /// Scaled against the largest section rather than the total, so the
    /// smaller kinds stay visible instead of collapsing to a hairline.
    private func share(_ tokens: Int, of largest: Int) -> Double {
        largest > 0 ? Double(tokens) / Double(largest) : 0
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

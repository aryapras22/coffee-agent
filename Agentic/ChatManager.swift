//
//  ChatManager.swift
//  Agentic
//
//  Created by Arya on 31/08/26.
//

import Foundation
import FoundationModels
import Observation
import SwiftData

/// Owns everything a chat needs: the active Chat Session, the persistence
/// context, and the rebuildable Model Session that answers prompts. Replaces
/// `ChatViewModel`. Kept on `@MainActor` alongside its `ModelContext` so the
/// two are never touched from different isolation domains.
@Observable
@MainActor
final class ChatManager {
    private(set) var chatSession: ChatSession
    private(set) var sessions: [ChatSession] = []
    private(set) var isResponding = false
    /// The steps of the run currently in flight. Empty between runs; the
    /// finished run's steps are written onto the assistant message instead.
    private(set) var liveSteps: [AgentStep] = []
    private(set) var transientFailure: String?
    /// The live transcript's share of the context window. Refreshed after
    /// every turn and every session rebuild, and left at its last value when
    /// the token count fails, so a transient error does not read as an empty
    /// context.
    private(set) var contextUsage: Double = 0
    var draft = ""

    /// Paired with `transientFailure` so the failure bubble keeps one stable
    /// identity across repeated reads of `displayMessages` — a fresh `UUID()`
    /// generated inside that computed property would change on every access
    /// and break `ForEach` identity and scroll-to-bottom.
    @ObservationIgnored private var failureID: UUID?

    private let context: ModelContext
    private let agent: CoffeeAgent
    @ObservationIgnored private var modelSession: LanguageModelSession

    /// Compaction fires once the live transcript reaches this fraction of the
    /// model's usable context window, leaving headroom for the summarizer's
    /// own prompt and the next reply.
    static let compactionThreshold = 0.75
    private static let maxRawMessages = 6

    init(context: ModelContext, agent: CoffeeAgent) {
        self.context = context
        self.agent = agent
        let session = Self.mostRecentOrNewSession(in: context)
        self.chatSession = session
        self.modelSession = agent.makeSession(recap: Self.recap(for: session, maxRawMessages: Self.maxRawMessages))
        refreshSessions()
        Task { await refreshContextUsage() }
    }

    /// Every replacement of the model session changes what the context holds,
    /// so the two always move together.
    private func rebuildSession(recap: String?) {
        modelSession = agent.makeSession(recap: recap)
        Task { await refreshContextUsage() }
    }

    /// Hands back the raw count as well, so a caller that also has to decide
    /// about compaction is not charged for a second count of the same transcript.
    @discardableResult
    private func refreshContextUsage() async -> Int? {
        let model = SystemLanguageModel.default
        guard let used = try? await model.tokenCount(for: modelSession.transcript) else { return nil }
        contextUsage = Double(used) / Double(model.contextSize)
        return used
    }

    private static func mostRecentOrNewSession(in context: ModelContext) -> ChatSession {
        let descriptor = FetchDescriptor<ChatSession>()
        let existing = (try? context.fetch(descriptor)) ?? []
        if let mostRecent = existing.max(by: { $0.lastActivity < $1.lastActivity }) {
            return mostRecent
        }
        let created = ChatSession()
        context.insert(created)
        return created
    }

    private func refreshSessions() {
        let descriptor = FetchDescriptor<ChatSession>()
        let fetched = (try? context.fetch(descriptor)) ?? []
        sessions = fetched.sorted { $0.lastActivity > $1.lastActivity }
    }

    static func recap(for chatSession: ChatSession, maxRawMessages: Int) -> String? {
        let sorted = chatSession.messages.sorted { $0.timestamp < $1.timestamp }
        var parts: [String] = []
        if let summary = chatSession.summary {
            parts.append("Summary of earlier conversation: " + summary)
        }
        let recent = sorted.suffix(maxRawMessages)
        if !recent.isEmpty {
            let text = recent.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
            parts.append("Most recent exchange:\n" + text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    var unavailableReason: String? {
        switch agent.model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to chat."
        case .unavailable(.modelNotReady):
            return "The model is still downloading. Try again shortly."
        case .unavailable:
            return "The on-device model is unavailable."
        }
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isResponding
    }

    var beanCount: Int { agent.beanCount }

    var canStartNewChat: Bool {
        !chatSession.messages.isEmpty && !isResponding
    }

    /// Sorted persisted messages projected to `DisplayMessage`, with the
    /// transient failure appended last. The trace and the map come off the
    /// message itself, so a reply redraws the same way whether it was just
    /// produced or loaded from the store.
    var displayMessages: [DisplayMessage] {
        var display = chatSession.messages
            .sorted { $0.timestamp < $1.timestamp }
            .map { message in
                DisplayMessage(
                    id: message.id,
                    role: message.role == .user ? .user : .agent,
                    text: message.content,
                    steps: message.steps,
                    places: message.places
                )
            }
        if let transientFailure, let failureID {
            display.append(DisplayMessage(id: failureID, role: .failure, text: transientFailure))
        }
        return display
    }

    func prepareIndex() async {
        do {
            try await agent.indexBeans()
        } catch {
            Log.write(.failure, "bean indexing failed: \(error)")
            failureID = UUID()
            transientFailure = "Could not index beans: \(error)"
        }
    }

    func send(_ text: String? = nil) async {
        let question = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }

        draft = ""
        transientFailure = nil
        failureID = nil
        isResponding = true
        liveSteps = []
        trackSteps(of: modelSession)
        await agent.placeLog.reset()
        defer {
            isResponding = false
            liveSteps = []
        }

        Log.write(.agent, "send \"\(question)\" context=\(contextUsage.formatted(.percent.precision(.fractionLength(0))))")

        let userMessage = ChatMessage(role: .user, content: question)
        userMessage.session = chatSession
        context.insert(userMessage)
        chatSession.messages.append(userMessage)

        do {
            let response = try await modelSession.respond(to: question)

            let assistantMessage = ChatMessage(role: .assistant, content: response.content)
            assistantMessage.session = chatSession
            context.insert(assistantMessage)
            chatSession.messages.append(assistantMessage)
            assistantMessage.steps = agent.steps(from: response.transcriptEntries)
            assistantMessage.places = await agent.placeLog.places
            Log.write(.agent, "replied in \(assistantMessage.steps.count) steps, \(assistantMessage.places.count) places")

            try context.save()
            refreshSessions()
            await summarizeIfNeeded()
        } catch {
            // The user's question was still asked, so it stays persisted even
            // though the model failed to answer it — only the failure itself
            // (and the missing assistant turn) is kept out of the store. This
            // save also prevents the earlier insert from lingering unsaved in
            // the context, where a later, unrelated save would flush it.
            try? context.save()
            refreshSessions()
            Log.write(.failure, "turn failed: \(error)")
            failureID = UUID()
            transientFailure = "\(error)"
        }
    }

    /// The session appends to its transcript as the run progresses, so
    /// observing it is what makes the trace live rather than a record read
    /// back once the answer has already arrived. Each change re-registers,
    /// because `withObservationTracking` fires `onChange` only once.
    private func trackSteps(of session: LanguageModelSession) {
        liveSteps = withObservationTracking {
            agent.steps(from: session.transcript)
        } onChange: { [weak self] in
            // Bound to a `let` before the task: capturing the capture-list
            // `self` directly is a mutable capture, which Swift 6 rejects.
            let manager = self
            Task { @MainActor in
                guard let manager, manager.isResponding, manager.modelSession === session else { return }
                manager.trackSteps(of: session)
            }
        }
    }

    /// A pure predicate pulled out of `summarizeIfNeeded()` so the threshold
    /// itself is testable without a real token count or model call.
    static func shouldCompact(usedTokens: Int, budget: Int) -> Bool {
        Double(usedTokens) >= Double(budget) * compactionThreshold
    }

    /// Both turns are already saved by the time this runs, so a throw here
    /// leaves the exchange durably stored with a stale-or-absent summary; the
    /// next turn re-evaluates the threshold and retries.
    private func summarizeIfNeeded() async {
        guard
            let used = await refreshContextUsage(),
            Self.shouldCompact(usedTokens: used, budget: SystemLanguageModel.default.contextSize)
        else { return }

        let sorted = chatSession.messages.sorted { $0.timestamp < $1.timestamp }
        let transcriptText = sorted.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")

        let summarizer = LanguageModelSession(
            instructions: "Summarize this conversation in under 80 words. Keep names, decisions, and open questions."
        )

        guard let summary = try? await summarizer.respond(to: transcriptText).content else {
            Log.write(.failure, "compaction summariser failed, retrying next turn")
            return
        }
        Log.write(.agent, "compacted \(sorted.count) messages into a \(summary.count) character summary")

        chatSession.summary = summary
        rebuildSession(recap: Self.recap(for: chatSession, maxRawMessages: Self.maxRawMessages))
        try? context.save()
    }

    func select(_ session: ChatSession) {
        guard !isResponding, session.id != chatSession.id else { return }
        chatSession = session
        rebuildSession(recap: Self.recap(for: session, maxRawMessages: Self.maxRawMessages))
        transientFailure = nil
        failureID = nil
    }

    /// The model keeps its own transcript, so clearing the messages is not
    /// enough: the session has to be replaced or the next answer still
    /// carries the old conversation.
    func newChat() {
        guard !isResponding else { return }
        let created = ChatSession()
        context.insert(created)
        try? context.save()
        chatSession = created
        rebuildSession(recap: nil)
        transientFailure = nil
        failureID = nil
        draft = ""
        refreshSessions()
    }

    func delete(_ session: ChatSession) {
        guard !isResponding else { return }
        let wasActive = session.id == chatSession.id
        context.delete(session)
        try? context.save()
        refreshSessions()
        if wasActive {
            chatSession = Self.mostRecentOrNewSession(in: context)
            rebuildSession(recap: Self.recap(for: chatSession, maxRawMessages: Self.maxRawMessages))
            transientFailure = nil
            failureID = nil
            refreshSessions()
        }
    }
}

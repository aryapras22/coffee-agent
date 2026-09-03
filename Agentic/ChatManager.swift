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

/// What the model is actually carrying, for the memory gauge to expand into.
/// The percentage on its own says how full the context is but not with what,
/// and the answer matters: a window filled with tool results behaves very
/// differently from one filled with conversation.
nonisolated struct ContextReport: Sendable {
    nonisolated struct Section: Identifiable, Sendable {
        let id: String
        let tokens: Int
        let entries: Int
    }

    let usedTokens: Int
    let budget: Int
    /// What a brand new session costs before a word is said: the persona plus
    /// every tool's argument schema. It never goes away, so the real room for
    /// conversation is the budget minus this.
    let fixedOverhead: Int
    /// Measured per group, so these do not sum to `usedTokens`: each count
    /// carries a little of the transcript's own framing. Shown as shares
    /// rather than as an addition for that reason.
    let sections: [Section]
    /// The compaction summary standing in for turns no longer held verbatim.
    let summary: String?
    let recentMessagesReplayed: Int

    var usage: Double { budget > 0 ? Double(usedTokens) / Double(budget) : 0 }

    var roomForConversation: Int { max(budget - fixedOverhead, 0) }
}

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
                    places: message.places,
                    cards: message.cards
                )
            }
        if let transientFailure, let failureID {
            display.append(DisplayMessage(id: failureID, role: .failure, text: transientFailure))
        }
        return display
    }

    /// What to offer under the composer. Empty while a turn is in flight, and
    /// after a user message that got no reply, so the chips never sit under a
    /// question the agent has not answered.
    var quickReplies: [String] {
        guard !isResponding, transientFailure == nil else { return [] }
        let sorted = chatSession.messages.sorted { $0.timestamp < $1.timestamp }
        guard let last = sorted.last else { return QuickReplies.opening }
        guard last.role == .assistant else { return [] }
        return QuickReplies.following(last.cards)
    }

    /// A reply the app wrote rather than the model: a bag was saved, a brew
    /// was logged, a verdict was taken. The facts in it are computed, not
    /// generated, so nothing here can be a hallucination.
    ///
    /// It does not enter the live model transcript. That is deliberate and it
    /// costs nothing: the cupboard, not the conversation, is what the tools
    /// read, and the next session rebuild folds this into the recap anyway.
    func post(_ text: String, cards: [ThreadCard] = []) {
        let message = ChatMessage(role: .assistant, content: text)
        message.session = chatSession
        context.insert(message)
        chatSession.messages.append(message)
        message.cards = cards
        try? context.save()
        refreshSessions()
        Log.write(.agent, "posted an app-authored reply, \(cards.count) cards")
    }

    /// One count for the whole transcript, which is exact, plus one per kind
    /// of entry, which is not. Five extra token counts at most, and only when
    /// someone opens the gauge.
    func contextReport() async -> ContextReport? {
        let model = SystemLanguageModel.default
        guard let used = try? await model.tokenCount(for: modelSession.transcript) else {
            Log.write(.failure, "context report unavailable, token count failed")
            return nil
        }

        var grouped: [String: [Transcript.Entry]] = [:]
        for entry in modelSession.transcript {
            grouped[Self.label(for: entry), default: []].append(entry)
        }

        var sections: [ContextReport.Section] = []
        for (label, entries) in grouped {
            let tokens = (try? await model.tokenCount(for: Transcript(entries: entries))) ?? 0
            sections.append(ContextReport.Section(id: label, tokens: tokens, entries: entries.count))
        }

        // Measured rather than assumed: the tool schemas dominate it, and they
        // change whenever a tool is added.
        let overhead = (try? await model.tokenCount(for: agent.makeSession().transcript)) ?? 0

        Log.write(.agent, "context report \(used)/\(model.contextSize), \(overhead) fixed, \(sections.count) kinds")
        return ContextReport(
            usedTokens: used,
            budget: model.contextSize,
            fixedOverhead: overhead,
            sections: sections.sorted { $0.tokens > $1.tokens },
            summary: chatSession.summary,
            recentMessagesReplayed: min(chatSession.messages.count, Self.maxRawMessages)
        )
    }

    private static func label(for entry: Transcript.Entry) -> String {
        switch entry {
        case .instructions: "Instructions"
        case .prompt: "Your messages"
        case .response: "Replies"
        case .toolCalls: "Tool calls"
        case .toolOutput: "Tool results"
        @unknown default: "Other"
        }
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
        await agent.cardLog.reset()
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
            assistantMessage.cards = await agent.cardLog.cards
            Log.write(.agent, "replied in \(assistantMessage.steps.count) steps, \(assistantMessage.places.count) places, \(assistantMessage.cards.count) cards")

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

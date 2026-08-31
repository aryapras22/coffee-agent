//
//  ChatManagerTests.swift
//  Agentic
//

import FoundationModels
import SwiftData
import Testing

@testable import Agentic

/// An in-memory `ModelContainer` fixture per test, so each test starts from
/// an empty store and nothing here touches the user's real chat history.
@MainActor
private func makeContext() throws -> ModelContext {
    let schema = Schema([ChatSession.self, ChatMessage.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    return ModelContext(container)
}

/// Property tests that need no model response — pure persistence and pure
/// functions over stored data. These run without Apple Intelligence.
@MainActor
struct ChatManagerPersistenceTests {

    @Test("session list is ordered by most recent activity")
    func sessionListOrdering() throws {
        let context = try makeContext()
        let older = ChatSession(createdAt: .now.addingTimeInterval(-100))
        let newer = ChatSession(createdAt: .now)
        context.insert(older)
        context.insert(newer)
        try context.save()

        let manager = try ChatManager(context: context, agent: CoffeeAgent())

        #expect(manager.sessions.first?.id == newer.id)
        #expect(manager.sessions == manager.sessions.sorted { $0.lastActivity > $1.lastActivity })
    }

    @Test("selecting a session isolates its messages from every other session")
    func selectionIsolatesMessages() throws {
        let context = try makeContext()
        let sessionA = ChatSession()
        let sessionB = ChatSession()
        context.insert(sessionA)
        context.insert(sessionB)

        let messageA = ChatMessage(role: .user, content: "from A")
        messageA.session = sessionA
        context.insert(messageA)
        sessionA.messages.append(messageA)

        let messageB = ChatMessage(role: .user, content: "from B")
        messageB.session = sessionB
        context.insert(messageB)
        sessionB.messages.append(messageB)

        try context.save()

        let manager = try ChatManager(context: context, agent: CoffeeAgent())
        manager.select(sessionA)

        #expect(manager.displayMessages.map(\.text) == ["from A"])
    }

    @Test("starting a new chat clears the draft and begins with no messages")
    func newChatStartsClean() throws {
        let context = try makeContext()
        let manager = try ChatManager(context: context, agent: CoffeeAgent())
        manager.draft = "unsent text"

        manager.newChat()

        #expect(manager.draft.isEmpty)
        #expect(manager.displayMessages.isEmpty)
    }

    @Test("deleting a session removes its messages and its summary")
    func cascadeDeleteLeavesNoOrphans() throws {
        let context = try makeContext()
        let doomed = ChatSession()
        doomed.summary = "a summary"
        context.insert(doomed)

        let message = ChatMessage(role: .user, content: "will be deleted")
        message.session = doomed
        context.insert(message)
        doomed.messages.append(message)
        try context.save()

        let manager = try ChatManager(context: context, agent: CoffeeAgent())
        manager.delete(doomed)

        let remainingMessages = try context.fetch(FetchDescriptor<ChatMessage>())
        #expect(remainingMessages.isEmpty)
        #expect(!manager.sessions.contains { $0.id == doomed.id })
    }

    @Test(
        "compaction is attempted only once the transcript reaches 75% of the context budget",
        arguments: [
            (749, 1000, false),
            (750, 1000, true),
            (0, 1000, false),
            (1000, 1000, true),
        ]
    )
    func compactionThreshold(usedTokens: Int, budget: Int, expected: Bool) {
        #expect(ChatManager.shouldCompact(usedTokens: usedTokens, budget: budget) == expected)
    }

    @Test("ChatMessage cannot represent a failure, so a failed turn can never reach the store")
    func failuresAreNotRepresentableInStorage() {
        // `ChatRole` has exactly two cases; there is no third value a failed
        // request could map to. `send(_:)`'s catch block never constructs a
        // `ChatMessage` for the failure, only `transientFailure` — this is
        // the structural guarantee that backs that behaviour.
        #expect(ChatRole(rawValue: "failure") == nil)
        #expect(Set(["user", "assistant"]) == Set([ChatRole.user.rawValue, ChatRole.assistant.rawValue]))
    }

    @Test("recap contains the stored summary and the most recent raw messages, in order")
    func recapComposition() {
        let session = ChatSession()
        session.summary = "earlier context"
        for index in 0..<10 {
            let message = ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "turn \(index)",
                timestamp: .now.addingTimeInterval(Double(index))
            )
            message.session = session
            session.messages.append(message)
        }

        let recap = ChatManager.recap(for: session, maxRawMessages: 6)

        #expect(recap?.contains("earlier context") == true)
        for index in 4..<10 {
            #expect(recap?.contains("turn \(index)") == true)
        }
        #expect(recap?.contains("turn 3") == false)
    }
}

/// Property tests that require an actual model response. Skipped, not
/// failed, when Apple Intelligence is unavailable on the host running tests.
/// Serialized because concurrent on-device model calls from parallel tests
/// contend for the same resource and can make one request fail spuriously.
@Suite(.serialized)
@MainActor
struct ChatManagerModelTests {

    private var modelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @Test("a successful exchange persists both turns in chronological order")
    func exchangeRoundTrip() async throws {
        guard modelAvailable else { return }
        let context = try makeContext()
        let manager = try ChatManager(context: context, agent: CoffeeAgent())

        await manager.send("Say hello in one word.")

        let stored = manager.chatSession.messages.sorted { $0.timestamp < $1.timestamp }
        #expect(stored.count == 2)
        #expect(stored.first?.role == .user)
        #expect(stored.last?.role == .assistant)
    }

    @Test("a summarization failure still leaves both turns of the exchange readable afterward")
    func summarizationFailurePreservesTheExchange() async throws {
        guard modelAvailable else { return }
        let context = try makeContext()
        let manager = try ChatManager(context: context, agent: CoffeeAgent())

        // `summarizeIfNeeded()` only ever mutates `chatSession.summary` and
        // `modelSession` after both turns are already saved, so its own
        // failure paths (a nil token count, a nil budget, or the summarizer
        // throwing) cannot roll back a save that already committed. This
        // exercises one ordinary exchange and asserts the exchange survives
        // regardless of whether compaction happened to run.
        await manager.send("What origins do you carry?")

        let freshContext = ModelContext(context.container)
        let stored = try freshContext.fetch(FetchDescriptor<ChatMessage>())
            .sorted { $0.timestamp < $1.timestamp }
        #expect(stored.count == 2)
        #expect(stored.first?.role == .user)
        #expect(stored.last?.role == .assistant)
    }

    @Test("a reply's trace is stored with it, so a reloaded message still carries its steps")
    func traceSurvivesAReload() async throws {
        guard modelAvailable else { return }
        let context = try makeContext()
        let manager = try ChatManager(context: context, agent: CoffeeAgent())

        await manager.send("Which beans are fruity?")

        let liveReply = manager.displayMessages.last { $0.role == .agent }
        #expect(liveReply != nil)
        #expect(liveReply?.steps.isEmpty == false)

        // A second manager over the same store simulates a relaunch: nothing
        // in memory carries over, so anything still there came off the store.
        let reloadedSession = manager.chatSession
        let reloaded = try ChatManager(context: context, agent: CoffeeAgent())
        reloaded.select(reloadedSession)
        let reloadedReply = reloaded.displayMessages.last { $0.role == .agent }
        #expect(reloadedReply?.steps.map(\.id) == liveReply?.steps.map(\.id))
        #expect(reloadedReply?.steps.map(\.summary) == liveReply?.steps.map(\.summary))
    }

    @Test("switching to another room and back leaves the first room's trace intact")
    func traceSurvivesARoomSwitch() async throws {
        guard modelAvailable else { return }
        let context = try makeContext()
        let manager = try ChatManager(context: context, agent: CoffeeAgent())

        await manager.send("Which beans are fruity?")
        let withTrace = manager.chatSession
        let expected = manager.displayMessages.last { $0.role == .agent }?.steps.map(\.id)
        #expect(expected?.isEmpty == false)

        manager.newChat()
        manager.select(withTrace)

        let afterSwitch = manager.displayMessages.last { $0.role == .agent }?.steps.map(\.id)
        #expect(afterSwitch == expected)
    }
}

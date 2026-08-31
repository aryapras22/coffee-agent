# Design Document

## Architecture

SwiftData owns durable conversation state, `LanguageModelSession` owns in-memory transcript state, and `ChatManager` is the only thing that touches both. `ChatViewModel` is deleted; `ContentView` observes `ChatManager`.

```
AgenticApp
  → .modelContainer(for: [ChatSession.self, ChatMessage.self])
    → ContentView
      → @Environment(\.modelContext)
        → ChatManager(context:agent:)
          → CoffeeAgent (tools, persona instructions, beanCount, availability)
```

```
ChatManager.send(_:)
  → persist user ChatMessage (role "user")
  → modelSession.respond(to:)
    → tools invoked by the model
  → persist assistant ChatMessage (role "assistant")
  → traces[assistantMessage.id] = agent.steps(from: response.transcriptEntries)
  → context.save()
  → summarizeIfNeeded()

ChatManager.summarizeIfNeeded()
  → SystemLanguageModel.default.tokenCount(for: modelSession.transcript)
  → compare against compactionThreshold (0.75 × model.contextSize)
  → short-lived summarizer LanguageModelSession
    → respond(to: transcript prose)
  → chatSession.summary = result
  → makeSession(tools:persona:recap:)
  → context.save()

ChatManager.activate(_:) — launch, session selection, new chat
  → chatSession.messages sorted by timestamp
  → recap(for:) → summary + last maxRawMessages messages
  → makeSession(tools:persona:recap:)
    → Instructions { persona; recap }
  → modelSession replaced
```

## Domain Types

```swift
@Model final class ChatSession {
    var id: UUID
    var createdAt: Date
    var summary: String?
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage]
}

@Model final class ChatMessage {
    var id: UUID
    var role: String        // "user" | "assistant"
    var content: String
    var timestamp: Date
    var session: ChatSession?
}
```

`role` is a stored `String` with a computed accessor, since only two values persist.

## Naming Collision

The in-memory `struct ChatMessage` in `ContentView.swift` is renamed `DisplayMessage` and becomes a view-layer projection, because it carries two things the store deliberately does not — the `.failure` role and `steps: [AgentStep]` — and rendering the `@Model` directly would force one of them into persistence.

`ChatManager.displayMessages` maps sorted persisted messages to `DisplayMessage`, attaching `traces[persistedID]` when present, then appends the `.failure` entry from `transientFailure`. Reloaded messages have no trace entry, so they render as plain text.

## ChatManager

`@Observable @MainActor final class ChatManager` holding `chatSession: ChatSession`, `context: ModelContext`, `tools: [any Tool]`, `personaInstructions: String`, `private var modelSession: LanguageModelSession` (marked `@ObservationIgnored`), and `private var traces: [UUID: [AgentStep]]`.

It absorbs `draft`, `isResponding`, `canSend`, `canStartNewChat`, `unavailableReason` and `beanCount` from the deleted `ChatViewModel` unchanged, and adds `sessions`, `select(_:)`, `newChat()` and `delete(_:)`.

`modelSession` is rebuilt in exactly three places — launch, session switch, and after compaction — so transcript and store cannot silently diverge.

## Compaction

Compaction fires when `tokenCount(for: modelSession.transcript)` reaches 75% of `model.contextSize`. The summarizer is a throwaway session instructed to produce a summary "under 80 words, keep names, decisions, and open questions". The result replaces `chatSession.summary` outright. `recap(for:)` emits the summary followed by the last `maxRawMessages: Int = 6` messages verbatim, so the most recent turns survive unparaphrased.

## Failure Strategy

`send(_:)` throws. `ContentView` catches at the call site and sets `transientFailure`, which renders as a failure bubble and is never written to the store. `newChat()` and `select(_:)` clear it.

Both messages and `context.save()` complete before `summarizeIfNeeded()` runs, so a summarization throw leaves the exchange durably stored with a stale-or-absent summary; the next turn re-evaluates the threshold and retries. Persistence failures from `context.save()` propagate out of `send(_:)` as the same transient failure.

## Trade-offs

Compaction folds everything accumulated so far into one summary rather than keeping the last N raw turns and summarizing only the rest, because a hybrid requires hand-building `Transcript` entries, which is unverified on iOS 26.

`LanguageModelSession(tools:transcript:)` as one combined initializer is unverified; `LanguageModelSession(transcript:)` alone is confirmed — this only matters if a trimmed-transcript approach later replaces full summarization.

`ChatManager` and its `ModelContext` are both `@MainActor`, so the context is never touched from two isolation domains; the cost is that summarization awaits on the main actor's cooperative queue.

## Testing Strategy

Property tests use an in-memory `ModelContainer` and a stubbed responder, minimum 100 iterations each. Real token counting and end-to-end compaction get one on-device integration test each.

## Correctness Properties

*A property is a characteristic or behavior that should hold true across all valid executions of a system-essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees.*

### Property 1: Exchange round-trip

For any non-empty prompt and any reply, after a successful `send(_:)` a fresh `ModelContext` over the same container returns both turns for that session with role, content and chronological order preserved.

**Validates: Requirements 1.1**

### Property 2: Session list ordering

For any set of stored Chat Sessions, the list `ChatManager` exposes is ordered by last activity descending.

**Validates: Requirements 1.2**

### Property 3: Selection isolates a session

For any store of several sessions with interleaved timestamps, selecting one yields displayed messages exactly equal to that session's messages in timestamp order, with none from any other session.

**Validates: Requirements 1.3**

### Property 4: New chat starts clean

For any prior state — any draft text, any number of existing sessions — after `newChat()` the active session has zero messages and the draft is empty.

**Validates: Requirements 1.4**

### Property 5: Cascade delete leaves no orphans

For any session holding any number of messages and any summary, after `delete(_:)` no `ChatMessage` in the store references that session and its summary is gone with it.

**Validates: Requirements 1.5**

### Property 6: Compaction threshold

For any transcript token count, compaction is attempted if and only if the count is at least 75% of the model's context size.

**Validates: Requirements 1.6**

### Property 7: Recap composition

For any session, the recap contains the stored summary when one exists and exactly the chronologically last `min(messageCount, maxRawMessages)` messages, in order.

**Validates: Requirements 1.7**

### Property 8: Trace availability follows the run

For any assistant reply produced in the current run, the trace fetched by that message's persisted id equals the steps derived from the response entries; for any message loaded from a previous run, no trace is available.

**Validates: Requirements 1.8, 1.9**

### Property 9: Failures are not persisted

For any error thrown by the model request, the store afterwards contains no message attributed to a failure and no assistant message for that turn.

**Validates: Requirements 1.10**

### Property 10: Summarization failure preserves the exchange

For any exchange followed by a summarization that throws, both persisted turns remain readable from a fresh context.

**Validates: Requirements 1.1, 1.6**

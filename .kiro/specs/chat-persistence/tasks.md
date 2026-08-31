# Implementation Plan: Chat Persistence

## Tasks

- [ ] 1. Store and app wiring
  - [ ] 1.1 Add the `ChatSession` and `ChatMessage` `@Model` types in a new `Agentic/ChatStore.swift`, with the cascade relationship and role accessor. _Requirements: 1.1, 1.5_
  - [ ] 1.2 Attach `.modelContainer(for: [ChatSession.self, ChatMessage.self])` to the `WindowGroup` in `AgenticApp.swift`. _Requirements: 1.1_
  - [ ] 1.3 Rename the in-memory `ChatMessage` struct in `ContentView.swift` to `DisplayMessage` and update every reference. _Requirements: 1.9_

- [ ] 2. ChatManager
  - [ ] 2.1 Create `Agentic/ChatManager.swift` as `@Observable @MainActor` holding session, context, tools, persona, `@ObservationIgnored modelSession` and traces, with `ChatViewModel`'s published surface moved over unchanged. _Requirements: 1.1_
  - [ ] 2.2 Add `recap(for:)` and a `CoffeeAgent.makeSession(recap:)` overload folding summary plus the last `maxRawMessages` turns into the persona `Instructions`. _Requirements: 1.7_
  - [ ] 2.3 Implement `send(_:)`: persist the user turn, await the reply, persist the assistant turn, record its trace under the persisted id, save, then call `summarizeIfNeeded()`, throwing on model or save failure. _Requirements: 1.1, 1.8, 1.10_
  - [ ] 2.4 Implement `displayMessages`, mapping sorted persisted messages to `DisplayMessage` with any in-run trace attached and `transientFailure` last. _Requirements: 1.8, 1.9, 1.10_
  - [ ] 2.5 Implement `summarizeIfNeeded()`: `tokenCount(for:)` against 75% of `contextSize`, summarise via a throwaway session, store the summary, rebuild `modelSession`, save. _Requirements: 1.6_
  - [ ] 2.6 Implement `sessions`, `select(_:)`, `newChat()` and `delete(_:)`, rebuilding `modelSession` and clearing `transientFailure` on each switch. _Requirements: 1.2, 1.3, 1.4, 1.5_

- [ ] 3. View layer
  - [ ] 3.1 Point `ContentView` at a `ChatManager` built from `@Environment(\.modelContext)`, render `displayMessages` and the failure bubble, delete `ChatViewModel`. _Requirements: 1.3, 1.9, 1.10_

- [ ] 4. Checkpoint - Ensure all tests pass, ask the user if questions arise.

- [ ] 5. Tests
  - [ ] 5.1 Add an in-memory `ModelContainer` fixture and a stub responder to `AgenticTests/CoffeeAgentTests.swift`. _Requirements: 1.1_
  - [ ] 5.2 Property tests **1 (exchange round-trip)**, **9 (failures not persisted)**, **10 (summarization failure preserves the exchange)**. _Requirements: 1.1, 1.6, 1.10_
  - [ ] 5.3 Property tests **2 (list ordering)**, **3 (selection isolates)**, **4 (new chat clean)**, **5 (cascade delete)**. _Requirements: 1.2, 1.3, 1.4, 1.5_
  - [ ] 5.4 Property tests **6 (compaction threshold)**, **7 (recap composition)**, **8 (trace follows the run)**. _Requirements: 1.6, 1.7, 1.8, 1.9_
  - [ ]* 5.5 On-device integration tests for real token counting and one end-to-end compaction, needing Apple Intelligence hardware. _Requirements: 1.6_

- [ ] 6. Checkpoint - Ensure all tests pass, ask the user if questions arise.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.2", "1.3"] },
    { "id": 1, "tasks": ["2.1"] },
    { "id": 2, "tasks": ["2.2"] },
    { "id": 3, "tasks": ["2.3"] },
    { "id": 4, "tasks": ["2.4"] },
    { "id": 5, "tasks": ["2.5"] },
    { "id": 6, "tasks": ["2.6"] },
    { "id": 7, "tasks": ["3.1", "5.1"] },
    { "id": 8, "tasks": ["5.2"] },
    { "id": 9, "tasks": ["5.3"] },
    { "id": 10, "tasks": ["5.4"] },
    { "id": 11, "tasks": ["5.5"] }
  ]
}
```

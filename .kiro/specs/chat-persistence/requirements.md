# Requirements Document

## Introduction

The Agentic coffee agent currently keeps a conversation in memory only, so quitting the app loses it and the on-device model session is the sole record of context. This slice stores conversations in SwiftData, lets the user move between past chats, and keeps a long conversation usable by summarising it before it outgrows the model's context window. A `ChatManager` replaces `ChatViewModel` as the single chat state owner that `ContentView` observes.

## Glossary

- **ChatManager**: The observable owner of all chat state, replacing ChatViewModel. Holds the active Chat Session, the persistence context, the agent's tools and persona instructions, and the rebuildable Model Session.
- **Chat Session**: One stored conversation, comprising its Chat Messages and its Conversation Summary.
- **Chat Message**: One stored turn of a Chat Session, attributed to the user or the agent.
- **Conversation Summary**: Stored prose standing in for the earlier part of a Chat Session that is no longer replayed to the model verbatim.
- **Model Session**: The `LanguageModelSession` that answers prompts. Its transcript lives in memory and starts empty on every app launch.
- **Tool Trace**: The tool calls and tool outputs behind a single agent reply, shown as expandable steps.

## Requirements

**User Story:** As someone browsing my coffee collection, I want my chats with the agent kept and reachable across launches, so that I can pick up a conversation instead of re-explaining what I am looking for.

### Acceptance Criteria

1. WHEN the user sends a message and the agent replies, THE ChatManager SHALL store both turns in the active Chat Session so they are present after the app is relaunched.
2. THE ChatManager SHALL expose the stored Chat Sessions as a list ordered by most recent activity first.
3. WHEN the user selects a Chat Session from the list, THE ChatManager SHALL make that session active and display its stored Chat Messages.
4. WHEN the user starts a new chat, THE ChatManager SHALL create an empty Chat Session, make it active, and clear the draft.
5. WHEN the user deletes a Chat Session, THE ChatManager SHALL remove that session together with its Chat Messages and its Conversation Summary.
6. WHEN the active Chat Session's Model Session transcript approaches the model's usable context window, THE ChatManager SHALL summarise the earlier conversation, store the result as the Conversation Summary, and rebuild the Model Session with that summary folded into the persona instructions.
7. WHEN a Chat Session becomes active after an app launch or a selection, THE ChatManager SHALL rebuild the Model Session from the stored Conversation Summary and the session's most recent Chat Messages, so the agent's next reply is consistent with the history the user can see.
8. WHERE an agent reply was produced during the current app run, THE ChatManager SHALL expose that reply's Tool Trace to ContentView.
9. WHEN a stored Chat Message is displayed after being reloaded from the store, THE ContentView SHALL render its text without a Tool Trace.
10. IF a request to the model fails, THEN THE ChatManager SHALL surface the failure to the user as a transient message that is left out of the stored Chat Session.

## Deferred

- MapKit tool for coffee places near the user.
- Tavily web search tool for beans outside the local corpus.
- Persisting Tool Traces so reloaded replies keep their steps.
- Hybrid compaction that keeps the last N raw turns alongside the Conversation Summary.

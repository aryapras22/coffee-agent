# Learning Notes

Two techniques here are worth understanding before implementing: rolling summarization for context-window management, and SwiftData's object graph. Both have failure modes that only surface later.

## Key terms

- **Token** — the unit a model actually counts, roughly three quarters of an English word. "Ethiopia" may be one token or three; never assume.
- **Context window** — the ceiling on tokens a model can consider at once, prompt and reply together. `SystemLanguageModel.default.contextSize` reports it. Exceed it and the request fails rather than degrades.
- **Transcript** — FoundationModels' in-memory record of a session's turns, replayed on every request. It is the only reason the model appears to remember anything.
- **Unit of work** — changes tracked in memory and committed together. `ModelContext` is one: mutate objects, then `save()` writes the batch.
- **Cascade delete** — deleting a parent deletes its children automatically, rather than leaving rows pointing at something gone.
- **Actor isolation / `@MainActor`** — a compiler-enforced promise that a type's state is only touched from one concurrency domain. `@MainActor` means the main thread.

## Rolling summarization

The model has no memory beyond its transcript. A fresh `LanguageModelSession` starts with an empty one, which is why a relaunched app has a full database and an amnesiac model. The database is our record; the transcript is the model's. They are separate stores that happen to describe the same conversation.

**Recap injection** closes that gap. Rather than replay every stored turn, we build a short prose recap — the summary plus the last few messages verbatim — and pass it inside `Instructions` when constructing the session. To the model this reads as standing context it was given up front, not as conversation it had. It is a *reconstruction*, not a restoration.

A long conversation outgrows the window eventually, so something has to shrink. Three approaches:

- **Sliding window** — keep the last N turns, drop the rest. Cheap, and lossy in the worst way: the goal stated in turn one is discarded first.
- **Rolling summarization** (this design) — compress everything so far into prose, store it, seed a fresh session with it. Detail is lost, intent survives.
- **Hybrid** — summarize old turns *and* replay the last N verbatim. Best fidelity, needs hand-built `Transcript` entries, which is why the design defers it.

Triggering on **token count** rather than message count matters because messages differ wildly in size — twenty short questions versus twenty replies quoting long tool output are an order of magnitude apart. A message-count trigger fires far too early on short chats or too late on verbose ones, and "too late" is a failed request, not a slow one. The 75% threshold leaves headroom for the summarizer's prompt and the next reply.

## SwiftData

`@Model` is a macro that rewrites a class into a persisted entity: stored properties become columns, and property access becomes change tracking. It requires a class, not a struct, because identity has to survive across fetches.

`ModelContext` is the unit of work. Objects you create or mutate are held as pending changes until `save()`. That is why the design saves at exchange boundaries rather than continuously — one save per completed turn, not one per keystroke.

`@Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)` says two things. `deleteRule: .cascade` means deleting a `ChatSession` deletes its messages. `inverse:` tells SwiftData that `ChatSession.messages` and `ChatMessage.session` are the two ends of *one* relationship, not two independent ones. Declare the inverse on **one side only** — declaring it on both makes the pairing ambiguous and SwiftData will either reject the model or treat them as separate relationships, which quietly breaks the cascade.

## Pitfalls

**Trusting the summary as fact.** A summary is a lossy paraphrase. After compaction the model may confidently restate something it half-remembers, so never treat it as the source of truth for anything checkable — bean names, dates, roast details. Re-search instead.

**Double-counting turns.** After compaction the transcript holds the recap and the store holds the raw messages. Replay the stored messages as well and the model sees the same exchange twice, then starts agreeing with itself. Keep the recap as the only path from store to transcript.

**Saving too often.** `save()` per keystroke turns a text field into disk I/O. Save when an exchange completes.

**Assuming cascade fires.** With `inverse:` wired wrongly, deleting a session leaves orphaned messages that reappear in later fetches. Test the delete path by fetching all messages afterwards.

**Touching `ModelContext` off the main actor.** It is not thread-safe. Both `ChatManager` and its context being `@MainActor` makes misuse a compile error rather than intermittent corruption. Background work later needs its own context, not this one.

**Compacting before saving.** If compaction ran first and threw, the exchange would be gone. Save first, compact second.

## Further reading

- [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
- [Transcript](https://developer.apple.com/documentation/foundationmodels/transcript)
- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [@Model](https://developer.apple.com/documentation/swiftdata/model())
- [@Relationship](https://developer.apple.com/documentation/swiftdata/relationship(_:deleteRule:minimumModelCount:maximumModelCount:originalName:inverse:hashValue:))
- [ModelContext](https://developer.apple.com/documentation/swiftdata/modelcontext)

The compaction pattern is general to conversational LLM systems, not Apple-specific — the same summarize-and-reseed loop appears anywhere a growing conversation has to fit a fixed window. Only the token-counting and session-construction APIs are FoundationModels'.

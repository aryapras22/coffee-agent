# Turning tool results into cards

## What this introduces

A side channel that carries a tool's structured result out of a model turn and into the view, so the transcript shows typed cards next to the reply rather than only the model's prose about them. `ThreadCard` is the payload, `CardLog` is the channel, `ChatManager.send` drains it onto the `ChatMessage`, and `ThreadCardView` draws it. It generalises the pattern `NearbyPlacesTool` and `PlaceLog` already used for one tool, and applies it to six.

## The problem it solves

A `Tool` has exactly one return value and the model is already using it. Whatever a tool returns is serialised into the transcript for the model to read, so it has to be small, flat, and worth spending context on. The view wants the opposite: everything the tool found, in full, with the fields the model has no use for.

Worse, anything the view reads out of the model's reply is a paraphrase. A cupping score quoted in a sentence is a token the model chose; a cupping score on a card is the number in the corpus file. Drawing cards from prose would put a generation step between the data and the display, which is exactly where a wrong figure enters.

## How the channel works

`CardLog` is an actor holding an array. `ChatManager.send` resets it before the turn, the tools append to it during the turn, and `send` reads it once the turn is over and writes the result onto the assistant `ChatMessage`. The tool's own return value is unchanged, so the model still sees what it needs and the view separately sees what it needs.

It appends rather than replaces, because one turn can call several tools and every result belongs under the same reply.

The cards are then persisted on the message as JSON, in the same style as the trace and the map pins. Persisting matters: rebuilding a card by re-running the search on scroll would show whatever the corpus returns today, not the bean the run actually found.

## Why this and not the alternatives

**Decode the tool output back out of the transcript.** `Transcript.Entry.toolOutput` carries the generated structure, and `AgentStep` already stores its JSON. Parsing that back into `BeanCard` would need no new plumbing. Rejected because it couples the view to the wire format of a `@Generable` type: adding a field the model does not need would mean adding it to the model's context anyway, which is the cost the channel exists to avoid.

**Return the cards from the tool.** Same problem, more directly: everything in the return value is spent on context.

**Have the view call the tools itself.** Then the card and the reply are two searches that can disagree, and the reply would cite a bean the card does not show.

The cost of the channel is that it is invisible in the type system. Nothing stops a tool from forgetting to append, and the result is a reply with no card rather than a compile error. The mitigation is that there is exactly one place per tool where it happens, next to the log line that already records the same result.

## The `offerChoices` inversion

Most cards report something found. `ChoiceCard` is the opposite: the model calls `offerChoices` to turn a question it is asking into tappable options, and `QuickReplies.following` gives those precedence over anything derived from the other cards.

The alternative was to guess reply chips from the conversation, and it fails on exactly the case that matters. The taste quiz asks two questions before it has any bean to show, so there are no cards to derive chips from, and a guessed list under a question the agent did not ask puts words in its mouth. Everything else in `QuickReplies` is derived, because the follow-ups after a bean card are always the same three and a model call for a fixed answer is latency for nothing.

## Terminology

**Side channel**: a path for data that deliberately bypasses the primary interface, here because the primary interface (the tool's return value) is metered by context cost.

**Structured output**: a tool result constrained to a schema by guided generation, so it is a typed value rather than text to parse.

**Actor as channel**: `CardLog` is an actor because tools run off the main actor inside the turn and the chat reads on it. The actor is the isolation boundary, not a queue; nothing here needs ordering guarantees beyond append order.

## Pitfalls

Reset before the turn, not after. Resetting afterwards leaves one run's cards visible to the next if the turn throws before its drain.

Card identifiers have to be derived from content, not generated. `displayMessages` decodes on every read, so a `UUID()` default would hand `ForEach` a new identity each frame and break both animation and scroll position. Every `ThreadCard.id` is built from the corpus id or the bean id for that reason.

An app-authored message is not in the model's live transcript. `ChatManager.post` writes an assistant message the app composed, and the model will not have seen it during the current session. That is fine here because the tools read the cupboard rather than the conversation, but it would not be fine for anything the model has to remember.

## Further reading

- Foundation Models: `Tool`, https://developer.apple.com/documentation/foundationmodels/tool
- Foundation Models: `Transcript`, https://developer.apple.com/documentation/foundationmodels/transcript
- Swift concurrency: actors, https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Actors

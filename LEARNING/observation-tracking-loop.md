# Re-registering observation tracking

## What this introduces

A one-shot change callback turned into a continuous stream, using `withObservationTracking(_:onChange:)` from the Observation framework. `ChatManager.trackSteps(of:)` uses it to mirror `LanguageModelSession.transcript` into a published `liveSteps` array while `respond(to:)` is still running, so the tool trace appears as the agent works rather than after it finishes.

## Why this and not the alternatives

`LanguageModelSession` is `Observable`, and its `transcript` grows as the model calls tools. Three ways to watch it:

Read `session.transcript` directly from the SwiftUI view. This works when the view holds the session, but here the session lives inside `ChatManager` behind `@ObservationIgnored`, and it is rebuilt whenever the chat is switched or the conversation is compacted. Exposing it to the view would make the view depend on an object whose identity changes underneath it.

Poll on a timer. Simple, but it either lags behind a fast tool call or burns main-actor work between calls.

`streamResponse` instead of `respond`. That streams the answer text, not the tool calls. The steps we want to show live are exactly the entries that do not appear in the content stream.

The cost of the chosen approach is that it is a manual loop. Nothing stops it on its own, so the re-registration has to be guarded, and a bug in the guard means the loop runs forever.

## How the logic works

`withObservationTracking` takes two closures. The first, `apply`, runs immediately and synchronously; every observable property read inside it is recorded as a dependency. The second, `onChange`, fires the next time any of those recorded properties is about to change.

`onChange` fires **once**. It is not a subscription. After it fires, the registration is spent and no further changes are reported. To keep watching, the tracking has to be set up again, which is why `trackSteps(of:)` calls itself from inside its own `onChange`.

The sequence per change:

1. `apply` reads `session.transcript`, builds the step list, and returns it. The transcript is now a tracked dependency.
2. The result is assigned to `liveSteps`, which is itself observable, so SwiftUI re-renders the thinking row.
3. The model appends a tool call to the transcript. `onChange` fires.
4. `onChange` schedules a `Task { @MainActor in ... }`, which checks the run is still in flight and the session has not been replaced, then calls `trackSteps(of:)` again — back to step 1.

The `Task` hop in step 4 matters. `onChange` fires on the *will-set* side of the change: the new value is not stored yet when the callback runs. Reading the transcript synchronously inside `onChange` would return the old value and the loop would sit one step behind forever. Hopping to a new main-actor task defers the read until after the write has landed.

The guard `self.isResponding && self.modelSession === session` is what terminates the loop. Once `send` returns, `isResponding` is false and the next callback declines to re-register. The identity check covers the case where the session was swapped out mid-run.

## Terminology

**Observation registrar** — the per-object bookkeeping the `@Observable` macro generates. It records which properties each active tracking scope read, and notifies matching scopes on write.

**Tracking scope** — one call to `withObservationTracking`. Alive from the moment `apply` runs until `onChange` fires, and no longer.

**will-set semantics** — the callback runs before the stored property is updated, not after. This is the opposite of what `onChange(of:)` in SwiftUI does, and is the single easiest thing to get wrong here.

## Pitfalls

Assuming `onChange` repeats. It does not. Without the recursive call the trace updates exactly once and then freezes.

Reading the changed value inside `onChange`. You get the pre-change value. Always re-read from a fresh task or a fresh `apply`.

Writing a tracked property inside `apply`. Reads inside `apply` become dependencies, so a property that is both read and written there will retrigger itself forever. `trackSteps` avoids this by having `apply` return the value and assigning to `liveSteps` outside the closure.

Forgetting a termination condition. The loop has no natural end; if the guard is wrong it re-registers indefinitely and holds the session alive.

Capturing `self` strongly. `onChange` outlives the call, so a strong capture keeps the manager alive past the point the view is gone.

## Further reading

- Observation framework reference: https://developer.apple.com/documentation/observation
- `withObservationTracking(_:onChange:)`: https://developer.apple.com/documentation/observation/withobservationtracking(_:onchange:)
- Foundation Models `LanguageModelSession`: https://developer.apple.com/documentation/foundationmodels/languagemodelsession
- `Transcript`: https://developer.apple.com/documentation/foundationmodels/transcript

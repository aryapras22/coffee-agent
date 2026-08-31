# Learning Notes

## Bridging a delegate API to async/await

`CLLocationManager` predates async/await — it reports back through delegate callbacks, not by returning a value. `withCheckedContinuation` lets one async function suspend, hand a `continuation` object to a stored property, return control to the delegate callback whenever it eventually fires, and resume the suspended function with whatever value the callback provides. The contract is strict: a continuation must be resumed exactly once. Resume it twice and the process traps; never resume it and the awaiting call hangs forever. That's why `LocationProvider` nils `continuation` immediately after resuming — a second, late callback for the same request finds nothing to resume.

## Status instead of throw, again

Same reasoning as the web-search tool: "no coordinate" is returned as data (`.locationUnavailable`), not thrown, because a status lets the model tell the person "location is unavailable" rather than concluding no cafes exist anywhere. Distinguishing *why* — denied permission vs. a transient failure — makes that message actionable: one case means "go check Settings", the other means "try again".

## Region is a bias, not a filter

`MKCoordinateRegion` passed to `MKLocalSearch.Request` biases the search toward that area; it is not a hard boundary. MapKit can return points of interest outside the stated radius if they're strong matches. If a strict radius matters, filter `PlaceHit.distanceMeters` against the requested radius after the search returns, rather than trusting the region to enforce it.

## Authorization states and one-shot location

CoreLocation's authorization status is one of: not determined, denied, restricted, or authorized (when-in-use or always). `requestLocation()` is one-shot — it fires a single delegate callback and stops, unlike `startUpdatingLocation()`'s continuous stream. That's the right choice for a tool call: the model needs one coordinate for one search, not a live feed.

## Terms

**Continuation** — a suspended function's "resume here" handle, held by `withCheckedContinuation` until something calls `resume(returning:)` or `resume(throwing:)`.

**Delegate pattern** — an object reports events by calling methods on another object (its delegate) that conforms to a known protocol, rather than returning values directly.

**Structured concurrency** — Swift's async/await model, where a suspended function's caller waits for it and cancellation propagates through that structure, rather than callbacks running detached from any caller.

**`@Generable`** — see the web-search-tool learn.md; same mechanism, same tool contract.

**Point of interest** — MapKit's category for named places (cafes, shops, landmarks) as opposed to bare addresses; `resultTypes = .pointOfInterest` scopes a search to them.

**Authorization status** — CoreLocation's enum reporting whether the app may access location, and at what precision/frequency tier.

## Pitfalls

Resuming a continuation twice. Guard it structurally (nil the reference after resuming) rather than trusting that callbacks won't overlap.

Leaking a continuation — storing it and then hitting a code path where neither delegate method ever fires (e.g., the manager is deallocated first). The suspended caller then hangs indefinitely.

Treating the search region as a strict radius filter. It isn't; sort and, if needed, post-filter results yourself.

Assuming a denied permission surfaces as a thrown error. It doesn't — `requestLocation()` calls `didFailWithError` or simply never calls `didUpdateLocations`; the tool must read `authorizationStatus` itself to tell denial apart from a transient miss.

Skipping the Info.plist usage string. Missing `NSLocationWhenInUseUsageDescription` doesn't fail gracefully — it terminates the app the moment authorization is requested.

## Further reading

- [MKLocalSearch](https://developer.apple.com/documentation/mapkit/mklocalsearch)
- [MKLocalSearch.Request](https://developer.apple.com/documentation/mapkit/mklocalsearch/request)
- [CLLocationManager](https://developer.apple.com/documentation/corelocation/cllocationmanager)
- [withCheckedContinuation](https://developer.apple.com/documentation/swift/withcheckedcontinuation(function:_:))
- [Tool (Foundation Models)](https://developer.apple.com/documentation/foundationmodels/tool)

# Design Document

## Architecture

`NearbyPlacesTool` follows `BeanSearchTool`'s shape: `call(arguments:)` returns a status distinguishing "ran, empty" from "did not run" rather than throwing for an ordinary failure.

    CoffeeAgent.makeSession()
      → tools: [spotlightTool, nearbyPlacesTool]
        → NearbyPlacesTool.call(arguments:)
          → locationProvider.currentCoordinate()
            → CLLocationManager.requestWhenInUseAuthorization() / requestLocation()
              → didUpdateLocations → continuation.resume(coordinate)
              → didFailWithError → continuation.resume(nil)
            → denied/restricted → continuation.resume(nil, reason: .denied) [see below]
          → coordinate present →
            MKCoordinateRegion(center:, latitudinalMeters: radius*2, longitudinalMeters: radius*2)
            → MKLocalSearch(request: naturalLanguageQuery, region, resultTypes: .pointOfInterest).start()
              → mapItems → PlaceHit(name, address, distance) → sort ascending
          → empty → .noMatchesNearby, else .matchesFound
        → PlaceSearchOutcome(status, places)

## Domain Types

`PlaceHit`, `PlaceSearchOutcome`, `NearbyPlacesTool` with `Arguments { query, radiusMeters: .range(200...5000) }` are the handed-off code as-is. Region spans `radiusMeters * 2` per side, per MapKit's meters-are-a-diameter convention for `MKCoordinateRegion(center:latitudinalMeters:longitudinalMeters:)`.

## Resolving Requirement 7

The handed-off three-case `PlaceSearchStatus` cannot tell the user "no cafes here" from "grant location access and try again". Resolution: keep the three cases, add a `reason: LocationUnavailableReason?` field on `PlaceSearchOutcome` (nil unless status is `.locationUnavailable`), with cases `.permissionDenied` and `.positionUnavailable`. A fourth status case was rejected — it would force every other call site to handle a case that only ever carries the same information a reason field carries more cheaply.

`LocationProvider.currentCoordinate()` therefore returns an enum, not a bare optional: `.available(CLLocationCoordinate2D)`, `.denied`, `.unavailable`. `authorizationStatus == .denied || .restricted` maps to `.denied` without calling `requestLocation()` at all.

## Mechanics

`resultTypes = .pointOfInterest` requires `naturalLanguageQuery` to be non-empty, or MapKit returns an undocumented `MKErrorGEOError=-8` — a real reported bug, not a documented constraint. The tool always sends the model's query string, never an empty one, closing this off structurally rather than by validation. Info.plist must declare `NSLocationWhenInUseUsageDescription` with a real user-facing string; its absence crashes the app on the first `requestWhenInUseAuthorization()` call rather than failing gracefully — this is a build-time checklist item, not code.

## Failure Strategy

No coordinate is data, not a throw: `.locationUnavailable` with a reason. `MKLocalSearch.start()` throwing (network failure, invalid region) propagates out of `call(arguments:)` as a thrown Swift error rather than a status, because that failure is orthogonal to location and BeanSearchTool's own precedent (`CSSearchQuery` errors) maps only index-availability failures to status, letting `call` mark this an integration-test gap rather than silently swallowing it. Reconsider this if the model needs a status for it in practice — the alternative is a fourth mapping to `.locationUnavailable`, but that would blur two unrelated causes into one status.

`CoffeeAgent.instructions` gains: "A status of locationUnavailable means the search did not run, not that no cafes exist. Say location is unavailable, do not say there are none nearby." — same shape as the existing `indexStale`/`indexUnavailable` line.

## Continuation Safety

Exactly one of `didUpdateLocations` / `didFailWithError` fires per `requestLocation()`, and `continuation` is nilled immediately after resuming in both, so a second delegate callback for the same request finds `nil` and resumes nothing — guarding against the double-resume trap.

## Trade-offs

Delegate + `withCheckedContinuation` rather than `CLLocationUpdate.liveUpdates()` (iOS 17+), which is cleaner but unverified this session — named in Deferred.

`authorizationStatus` is read once; if the person answers the permission dialog while `requestLocation()` is already pending, the code does not wait for `locationManagerDidChangeAuthorization(_:)` — acceptable for a first pass, unsafe to ship as-is.

Under Swift 6 strict concurrency, mutating `continuation` from a delegate callback needs explicit isolation (`@unchecked Sendable` or an actor); not handled in this design.

## Testing Strategy

Unit tests stub `LocationProvider` to cover: available coordinate with matches, available coordinate with no matches, `.denied`, `.unavailable`, asserting `PlaceSearchOutcome.status` and `.reason`. `MKLocalSearch` itself is not mocked — one on-device integration test exercises a real search.

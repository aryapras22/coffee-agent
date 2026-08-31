# Implementation Plan: Nearby Places Tool

## Tasks

- [ ] 1. Add `PlaceSearchStatus`, `LocationUnavailableReason`, `PlaceHit`, `PlaceSearchOutcome` to a new `Agentic/NearbyPlacesTool.swift`. _Requirements: 1, 3, 4, 5, 6, 7_
- [ ] 2. Implement `LocationProvider` with the delegate-to-continuation bridge, resolving to available/denied/unavailable and guaranteeing single resume. _Requirements: 6, 7, 8_
- [ ] 3. Implement `NearbyPlacesTool` with `Arguments` (`query`, `radiusMeters` ranged 200...5000) and `call(arguments:)` per design's region and status branching. _Requirements: 1, 2, 3, 4, 5, 6, 7_
- [ ] 4. Add `NSLocationWhenInUseUsageDescription` to Info.plist with a real user-facing string. _Requirements: 10_
- [ ] 5. Add the locationUnavailable instruction line to `CoffeeAgent.instructions` and register `NearbyPlacesTool` in `CoffeeAgent.makeSession()`. _Requirements: 9_
- [ ] 6. Checkpoint - Ensure the project builds, ask the user if questions arise.
- [ ] 7. Add unit tests stubbing `LocationProvider` for available-with-matches, available-with-none, denied, and unavailable, asserting status and reason. _Requirements: 4, 5, 6, 7, 8_
- [ ]* 8. Run one on-device integration test exercising a real `MKLocalSearch` call. _Requirements: 1, 3_
- [ ] 9. Checkpoint - Ensure all tests pass, ask the user if questions arise.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1"] },
    { "id": 1, "tasks": ["2"] },
    { "id": 2, "tasks": ["3"] },
    { "id": 3, "tasks": ["4", "5"] },
    { "id": 4, "tasks": ["6"] },
    { "id": 5, "tasks": ["7", "8"] },
    { "id": 6, "tasks": ["9"] }
  ]
}
```

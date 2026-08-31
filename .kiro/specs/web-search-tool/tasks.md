# Implementation Plan: Web Search Tool

## Tasks

- [ ] 1. Add `WebSearchStatus`, `WebSearchHit`, `WebSearchOutcome`, `RequestBody`, `ResponseBody` to a new `Agentic/WebSearchTool.swift`. _Requirements: 1, 2, 3, 4_
- [ ] 2. Implement `WebSearchTool` with `Arguments` (`query`, `maxResults` ranged 1...5) and `call(arguments:)` per design's status branching. _Requirements: 1, 2, 3, 4, 5_
- [ ] 3. Add key loading via a gitignored `.xcconfig` surfaced into Info.plist, and wire an empty/missing key to `.searchUnavailable` with no network call. _Requirements: 6, 7_
- [ ] 4. Add the searchUnavailable instruction line to `CoffeeAgent.instructions` and register `WebSearchTool` in `CoffeeAgent.makeSession()`. _Requirements: 8_
- [ ] 5. Checkpoint - Ensure the project builds, ask the user if questions arise.
- [ ] 6. Add unit tests for 200-with-results, 200-empty, non-200, malformed body, and missing key, asserting the returned status. _Requirements: 3, 4, 5, 6_
- [ ]* 7. Run one real Tavily request, print the raw response body, and confirm or correct `ResponseBody`'s field names. _Requirements: 5_
- [ ] 8. Checkpoint - Ensure all tests pass, ask the user if questions arise.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1"] },
    { "id": 1, "tasks": ["2", "3"] },
    { "id": 2, "tasks": ["4"] },
    { "id": 3, "tasks": ["5"] },
    { "id": 4, "tasks": ["6", "7"] },
    { "id": 5, "tasks": ["8"] }
  ]
}
```

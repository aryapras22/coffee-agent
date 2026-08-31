# Requirements Document

## Introduction

The Agentic coffee agent can search its indexed bean collection but knows nothing about the physical world around the user. This feature adds a second FoundationModels tool, NearbyPlacesTool, that finds cafes and coffee shops near the user's current position using MapKit local search, and a LocationProvider that supplies the user's coordinate to that tool. The tool follows the contract already set by BeanSearchTool: generable arguments with guided descriptions and validated ranges, a status that separates "ran and found nothing" from "did not run", and an outcome pairing that status with the hits.

## Glossary

- **NearbyPlacesTool**: The FoundationModels tool that searches for points of interest near the user and returns them to the model.
- **LocationProvider**: The component that reports the user's current coordinate, or reports that no coordinate is available.
- **CoffeeAgent**: The existing agent that owns the tool list and the model instructions.
- **Place_Hit**: One returned point of interest, carrying its name, its address, and its distance from the user.
- **Search_Status**: The value on the tool's outcome stating whether the search found matches, found nothing, or could not run.
- **Agentic_App**: The iOS application target that hosts the agent.

## Requirements

**User Story:** As someone using the coffee agent, I want to ask it for cafes near me, so that I can act on its answer without leaving the conversation to open a maps app.

### Acceptance Criteria

1. WHEN the model invokes NearbyPlacesTool with a search query and a search radius, THE NearbyPlacesTool SHALL return the points of interest matching that query within that radius of the user's current coordinate.
2. THE NearbyPlacesTool SHALL describe its query and radius arguments to the model and constrain the radius to a valid range.
3. THE NearbyPlacesTool SHALL order returned Place_Hit values nearest first by distance from the user's coordinate.
4. WHEN a search completes with at least one point of interest, THE NearbyPlacesTool SHALL return a Search_Status of matches found together with the Place_Hit values.
5. WHEN a search completes with no points of interest, THE NearbyPlacesTool SHALL return a Search_Status stating that the search ran and found nothing nearby.
6. IF the user's coordinate is unavailable, THEN THE NearbyPlacesTool SHALL return a Search_Status stating that the search did not run, together with an empty result set.
7. IF the user's coordinate is unavailable because location authorization was refused, THEN THE NearbyPlacesTool SHALL report that cause distinctly from a coordinate that was simply not obtained, so the user learns that granting access would fix the answer.
8. WHEN asked for the user's coordinate, THE LocationProvider SHALL return to its caller either a coordinate or an explicit absent result.
9. WHEN a tool result carries a Search_Status stating the search did not run, THE CoffeeAgent SHALL tell the user that nearby search is unavailable rather than that no cafes exist.
10. THE Agentic_App SHALL declare a when-in-use location usage description so the first authorization request completes instead of terminating the application.

## Deferred

- Replacing the delegate-to-async bridge in LocationProvider with `CLLocationUpdate.liveUpdates()`.
- Handling `locationManagerDidChangeAuthorization(_:)` so a request made while the permission dialog is open resolves correctly.
- Annotating the location continuation for Swift 6 strict concurrency.
- Opening a returned place in the Maps app.

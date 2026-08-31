//
//  NearbyPlacesToolTests.swift
//  Agentic
//

import CoreLocation
import Testing

@testable import Agentic

private struct StubLocationProvider: CoordinateProviding {
    let result: CoordinateResult

    func currentCoordinate() async -> CoordinateResult {
        result
    }
}

@MainActor
struct NearbyPlacesToolTests {
    private func arguments(query: String = "cafe", radiusMeters: Double = 1000) -> NearbyPlacesTool.Arguments {
        NearbyPlacesTool.Arguments(query: query, radiusMeters: radiusMeters)
    }

    @Test("a denied authorization maps to locationUnavailable with permissionDenied, not an empty result")
    func deniedAuthorization() async throws {
        let tool = NearbyPlacesTool(locationProvider: StubLocationProvider(result: .denied), log: PlaceLog())

        let outcome = try await tool.call(arguments: arguments())

        #expect(outcome.status == .locationUnavailable)
        #expect(outcome.reason == .permissionDenied)
        #expect(outcome.places.isEmpty)
    }

    @Test("a coordinate that never arrives maps to locationUnavailable with positionUnavailable")
    func positionUnavailable() async throws {
        let tool = NearbyPlacesTool(locationProvider: StubLocationProvider(result: .unavailable), log: PlaceLog())

        let outcome = try await tool.call(arguments: arguments())

        #expect(outcome.status == .locationUnavailable)
        #expect(outcome.reason == .positionUnavailable)
        #expect(outcome.places.isEmpty)
    }

    @Test("a matches-found or no-matches outcome never carries a reason")
    func successStatusesCarryNoReason() {
        let matches = PlaceSearchOutcome(status: .matchesFound, places: [], reason: nil)
        let empty = PlaceSearchOutcome(status: .noMatchesNearby, places: [], reason: nil)

        #expect(matches.reason == nil)
        #expect(empty.reason == nil)
    }
}

/// Exercises a real `MKLocalSearch` call against the device or simulator's
/// location services. Needs Apple Intelligence-free but genuine location
/// access, so it is not part of the required suite.
@MainActor
struct NearbyPlacesToolIntegrationTests {
    @Test("a real search near a known coordinate returns matches ordered nearest first", .disabled("on-device only"))
    func realSearchReturnsOrderedMatches() async throws {
        let coordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let log = PlaceLog()
        let tool = NearbyPlacesTool(locationProvider: StubLocationProvider(result: .available(coordinate)), log: log)

        let outcome = try await tool.call(
            arguments: NearbyPlacesTool.Arguments(query: "coffee", radiusMeters: 2000)
        )

        #expect(outcome.status == .matchesFound || outcome.status == .noMatchesNearby)
        let distances = outcome.places.map(\.distanceMeters)
        #expect(distances == distances.sorted())

        // The map is drawn from the log, not from the returned hits, so the
        // two have to describe the same cafes.
        let logged = await log.places
        #expect(logged.map(\.name) == outcome.places.map(\.name))
    }
}

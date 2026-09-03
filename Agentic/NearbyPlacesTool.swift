//
//  NearbyPlacesTool.swift
//  Agentic
//
//  Created by Arya on 31/08/26.
//

import CoreLocation
import FoundationModels
import MapKit

@Generable
enum PlaceSearchStatus {
    case matchesFound
    case noMatchesNearby
    case locationUnavailable
}

@Generable
enum LocationUnavailableReason {
    case permissionDenied
    case positionUnavailable
}

@Generable
struct PlaceHit {
    var name: String
    var address: String
    var distanceMeters: Double
}

@Generable
struct PlaceSearchOutcome {
    var status: PlaceSearchStatus
    var places: [PlaceHit]
    /// Non-nil only when `status` is `.locationUnavailable`, so the model can
    /// tell a refused permission apart from a coordinate that simply never
    /// arrived — one is fixable by the user, the other isn't.
    var reason: LocationUnavailableReason?
}

/// The same cafes the model is told about, plus the coordinates it has no use
/// for. Kept out of `PlaceHit` so the transcript does not carry latitudes the
/// model can only misquote, and out of the tool's return value so the map is
/// drawn from what MapKit actually found rather than from generated text.
nonisolated struct MappedPlace: Identifiable, Sendable, Codable {
    let name: String
    let address: String
    let distanceMeters: Double
    let latitude: Double
    let longitude: Double

    /// Derived rather than stored: a `UUID()` default would be regenerated on
    /// every decode, and `displayMessages` decodes on every read, so the
    /// `ForEach` would see a new identity each time it rendered.
    var id: String { "\(name)@\(latitude),\(longitude)" }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A side channel from the tool to the view. The tool runs deep inside a model
/// turn with nowhere to return a second value to, so it writes here and the
/// chat reads it once the turn is over.
actor PlaceLog {
    private(set) var places: [MappedPlace] = []

    /// Appends rather than replaces, because one turn can search more than once
    /// and every cafe it found belongs on the same map.
    func append(_ found: [MappedPlace]) {
        places.append(contentsOf: found)
    }

    func reset() {
        places = []
    }
}

struct NearbyPlacesTool: Tool {
    let name = "findNearbyCafes"
    let description = "Finds cafes or coffee shops near the person's current location."

    /// The only cap the model cannot raise, because it is not an argument.
    /// Every other tool bounds its results with a `limit` guide; this one
    /// returned however many MapKit felt like.
    static let maxReported = 5

    /// Street and area, without the province, postcode and country that every
    /// result in one search repeats. The map handoff keeps the full address.
    static func brief(_ address: String) -> String {
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.prefix(2).joined(separator: ", ")
    }

    let locationProvider: CoordinateProviding
    let log: PlaceLog
    /// Defaulted so the tool stays constructible without the chat around it.
    var cards: CardLog?

    @Generable
    struct Arguments {
        @Guide(description: "What kind of place to search for, e.g. cafe, espresso bar, roastery")
        var query: String

        @Guide(description: "Search radius in meters", .range(200...5000))
        var radiusMeters: Double
    }

    func call(arguments: Arguments) async throws -> PlaceSearchOutcome {
        let coordinate: CLLocationCoordinate2D
        switch await locationProvider.currentCoordinate() {
        case .available(let value):
            coordinate = value
        case .denied:
            return PlaceSearchOutcome(status: .locationUnavailable, places: [], reason: .permissionDenied)
        case .unavailable:
            return PlaceSearchOutcome(status: .locationUnavailable, places: [], reason: .positionUnavailable)
        }

        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: arguments.radiusMeters * 2,
            longitudinalMeters: arguments.radiusMeters * 2
        )

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = arguments.query
        request.region = region
        request.resultTypes = .pointOfInterest

        let response = try await MKLocalSearch(request: request).start()
        let userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        let found = response.mapItems.map { item -> MappedPlace in
            let itemLocation = item.location
            return MappedPlace(
                name: item.name ?? "Unknown",
                address: item.address?.fullAddress ?? "",
                distanceMeters: userLocation.distance(from: itemLocation),
                latitude: itemLocation.coordinate.latitude,
                longitude: itemLocation.coordinate.longitude
            )
        }.sorted { $0.distanceMeters < $1.distanceMeters }

        // Every pin still goes on the map: coordinates are cheap and the map
        // is the right place to see twenty of something.
        await log.append(found)

        // The model and the thread get the nearest few. MapKit will happily
        // return twenty five results, and a full address each is enough to
        // overflow the context window on its own, which is what it did.
        let reported = Array(found.prefix(Self.maxReported))
        await cards?.append(
            reported.map { place in
                .seller(
                    SellerCard(
                        name: place.name,
                        detail: "\(Int(place.distanceMeters))m away. \(place.address)",
                        url: nil,
                        source: "via Maps"
                    )
                )
            }
        )

        let hits = reported.map {
            PlaceHit(name: $0.name, address: Self.brief($0.address), distanceMeters: $0.distanceMeters)
        }
        Log.write(.tool, "findNearbyCafes \(found.count) found, \(hits.count) reported")

        return PlaceSearchOutcome(
            status: found.isEmpty ? .noMatchesNearby : .matchesFound,
            places: hits,
            reason: nil
        )
    }
}

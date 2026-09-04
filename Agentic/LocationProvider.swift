//
//  LocationProvider.swift
//  Agentic
//
//  Created by Arya on 31/08/26.
//

import CoreLocation

enum CoordinateResult {
    case available(CLLocationCoordinate2D)
    case denied
    case unavailable
}

/// Narrows `LocationProvider` to the one call `NearbyPlacesTool` needs, so
/// tests can substitute a stub without touching real Core Location.
protocol CoordinateProviding: Sendable {
    func currentCoordinate() async -> CoordinateResult
}

/// Where the user is, coarsely. Deliberately a place name and not a
/// coordinate: this is the value that leaves the device, and a town and
/// country are enough to bias a search without handing a third party the
/// user's position.
nonisolated struct CoarsePlace: Sendable, Equatable {
    let locality: String?
    let country: String?

    var described: String? {
        let parts = [locality, country].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Resolves a coordinate to a town and country, once. `CLGeocoder` is rate
/// limited by the system, and the answer does not change between two searches
/// in the same sitting, so the first result is kept for the session.
actor PlaceResolver {
    private let coordinates: CoordinateProviding
    private var cached: CoarsePlace?
    private var resolved = false

    init(coordinates: CoordinateProviding) {
        self.coordinates = coordinates
    }

    func currentPlace() async -> CoarsePlace? {
        if resolved { return cached }

        guard case .available(let coordinate) = await coordinates.currentCoordinate() else {
            Log.write(.tool, "no location for search context")
            // Not marked resolved: permission can be granted later, and a
            // refusal now should not silence every search afterwards.
            return nil
        }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            Log.write(.failure, "reverse geocoding failed, searching without a place")
            return nil
        }

        resolved = true
        cached = CoarsePlace(locality: mark.locality, country: mark.country)
        Log.write(.tool, "search context resolved to \(cached?.described ?? "nowhere")")
        return cached
    }
}

/// Bridges `CLLocationManager`'s delegate callbacks to async/await.
/// `CLLocationManager` predates structured concurrency, so there is no
/// awaitable equivalent of `requestLocation()` to call directly.
final class LocationProvider: NSObject, CLLocationManagerDelegate, CoordinateProviding, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func currentCoordinate() async -> CoordinateResult {
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            return .denied
        }
        manager.requestWhenInUseAuthorization()

        let coordinate = await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
        guard let coordinate else { return .unavailable }
        return .available(coordinate)
    }

    /// Resuming is paired with nilling the stored continuation, so a second
    /// delegate callback for the same request — which should not happen, but
    /// would trap the process if it did — finds nothing left to resume.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        continuation?.resume(returning: locations.first?.coordinate)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

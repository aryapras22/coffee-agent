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

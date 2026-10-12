//  LocationModel.swift
//  Keeps the current area name (e.g. "Riffa, Bahrain") up to date.

import CoreLocation

final class LocationModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastGeocoded: CLLocation?

    @Published private(set) var placeName: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // Only look up the name again after moving more than 100 m.
        if let last = lastGeocoded, placeName != nil, location.distance(from: last) < 100 { return }
        guard !geocoder.isGeocoding else { return }

        geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "en_US")) { [weak self] places, _ in
            guard let self, let place = places?.first else { return }
            let area = place.subLocality ?? place.locality ?? place.administrativeArea
            var parts: [String] = []
            if let area { parts.append(area) }
            if let country = place.country, country != area { parts.append(country) }
            guard !parts.isEmpty else { return }

            DispatchQueue.main.async {
                self.placeName = parts.joined(separator: ", ")
                self.lastGeocoded = location
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last known name; nothing else to do.
    }
}

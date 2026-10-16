//  LocationModel.swift
//  Current location, its area name (e.g. "Riffa, Bahrain"), and name lookups for any spot.

import Foundation
import CoreLocation
import MapKit

final class LocationModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published private(set) var current: CLLocation?
    @Published private(set) var placeName: String?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Goes up whenever a new location or name arrives (used to fill in photos taken without one).
    @Published private(set) var updateCount = 0
    /// Compass direction the camera is facing, in degrees from north (only while wanted).
    @Published private(set) var heading: Double?
    private var headingWanted = false
    /// While paused, the last good direction is kept (e.g. when the camera points at the floor).
    private var headingPaused = false

    private var cache: [(location: CLLocation, name: String)] = []
    private var waiting: [String: [(String?) -> Void]] = [:]
    /// When a lookup for a spot last failed.
    private var failedAt: [String: Date] = [:]
    private var lastLookup = Date.distantPast

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    override init() {
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 30
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        updateHeading()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    // MARK: Compass

    /// Turns the compass on or off (it's only used when the direction is on the stamp).
    func setHeadingWanted(_ on: Bool) {
        headingWanted = on
        updateHeading()
    }

    /// Keeps the last good direction while the reading would be unreliable.
    func setHeadingPaused(_ paused: Bool) {
        headingPaused = paused
    }

    /// Which way the phone is held, so the direction is the one the camera faces.
    func setHeadingOrientation(_ orientation: CLDeviceOrientation) {
        if manager.headingOrientation != orientation { manager.headingOrientation = orientation }
    }

    private func updateHeading() {
        guard CLLocationManager.headingAvailable() else { return }
        if headingWanted {
            manager.headingFilter = 2
            manager.startUpdatingHeading()
        } else {
            manager.stopUpdatingHeading()
            heading = nil
        }
    }

    // MARK: Names

    /// A name already looked up within 150 m of this spot.
    func cachedName(near location: CLLocation) -> String? {
        cache.first { $0.location.distance(from: location) < 150 }?.name
    }

    /// Looks up the area name for a spot (cached; one lookup per area at a time).
    func requestName(for location: CLLocation, completion: @escaping (String?) -> Void) {
        if let name = cachedName(near: location) {
            completion(name)
            return
        }
        let key = String(format: "%.3f,%.3f", location.coordinate.latitude, location.coordinate.longitude)
        // A lookup for this spot failed a moment ago (e.g. weak internet): wait 30 s before
        // asking again, so Apple doesn't limit the lookups.
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < 30 {
            completion(nil)
            return
        }
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return
        }
        waiting[key] = [completion]
        lastLookup = Date()

        Task {
            let name = await PlaceNamer.name(for: location)
            await MainActor.run {
                if let name {
                    self.cache.append((location, name))
                    self.failedAt[key] = nil
                } else {
                    self.failedAt[key] = Date()
                }
                let callbacks = self.waiting.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(name) }
                self.updateCount += 1
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy < 1000 else { return }
        current = location
        updateCount += 1

        if let name = cachedName(near: location) {
            if placeName != name { placeName = name }
            return
        }
        // Don't flood Apple's servers while moving: at most one new lookup every 5 seconds.
        guard placeName == nil || Date().timeIntervalSince(lastLookup) > 5 else { return }
        requestName(for: location) { [weak self] name in
            guard let self, let name,
                  let now = self.current, now.distance(from: location) < 150 else { return }
            self.placeName = name
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Skip readings the compass itself isn't sure about.
        guard headingWanted, !headingPaused,
              newHeading.headingAccuracy >= 0, newHeading.headingAccuracy <= 30 else { return }
        heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last known location; updates resume on their own.
    }
}

// MARK: - Area name lookup

enum PlaceNamer {
    /// Uses Apple's new API on iOS 26, and the classic one on older iOS (or if the new one fails).
    static func name(for location: CLLocation) async -> String? {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if let name = await modernName(for: location) { return name }
        }
        #endif
        return await classicName(for: location)
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private static func modernName(for location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = Locale(identifier: "en_US")
        return await withCheckedContinuation { continuation in
            request.getMapItems { items, _ in
                let address = items?.first?.addressRepresentations
                continuation.resume(returning: join(address?.cityName, address?.regionName))
            }
        }
    }
    #endif

    private static func classicName(for location: CLLocation) async -> String? {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "en_US")) { places, _ in
                let place = places?.first
                let area = place?.subLocality ?? place?.locality ?? place?.administrativeArea
                continuation.resume(returning: join(area, place?.country))
            }
        }
    }

    /// "Area, Country" (without repeating the country).
    private static func join(_ area: String?, _ country: String?) -> String? {
        var parts: [String] = []
        if let area, !area.isEmpty { parts.append(area) }
        if let country, !country.isEmpty, country != area { parts.append(country) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

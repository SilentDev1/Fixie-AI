// Services/LocationService.swift
// Real-time CoreLocation + reverse-geocoding + WeatherKit.
//
// Stability notes:
//   • distanceFilter = 500 m  — suppresses GPS jitter updates
//   • weatherFailureDate      — 5-minute backoff after WeatherKit JWT error (Code=2)
//     so the service doesn't flood @Observable state (and trigger view re-renders)
//     once per second while the JWT is unavailable
//   • State writes are guarded with equality checks so unchanged values never
//     trigger unnecessary SwiftUI re-renders
//
// SETUP:
//   NSLocationWhenInUseUsageDescription in Info.plist (already set)
//   WeatherKit capability in Signing & Capabilities (already added)

import CoreLocation
import WeatherKit

@Observable @MainActor
final class LocationService: NSObject {

    static let shared = LocationService()

    // MARK: – Published state

    var currentLocation: CLLocation?
    var cityState: String = ""                  // populated after first GPS fix
    var postalCode: String = ""                 // populated after first reverse-geocode
    var temperatureFahrenheit: Double? = nil
    var weatherCondition: String = ""
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    // MARK: – Private

    // @ObservationIgnored: CLLocationManager is not UI state — changes must never
    // trigger SwiftUI re-renders. Same for weatherFailureDate (backoff timestamp).
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var weatherFailureDate: Date?
    private static let weatherRetryInterval: TimeInterval = 5 * 60

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter  = 500   // ignore updates smaller than 500 m
    }

    // MARK: – Public API

    /// Call once at app launch to request permission and start location updates.
    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    /// Human-readable context string injected into Gemini prompts.
    /// Example: "Manchester, NH, 22°F, Overcast"
    var contextString: String {
        var parts: [String] = []
        if !cityState.isEmpty { parts.append(cityState) }
        if let temp = temperatureFahrenheit {
            parts.append(String(format: "%.0f°F", temp))
        }
        if !weatherCondition.isEmpty {
            parts.append(weatherCondition)
        }
        return parts.joined(separator: ", ")
    }

    // MARK: – Internal fetches

    fileprivate func handleNewLocation(_ location: CLLocation) {
        currentLocation = location
        Task {
            await reverseGeocode(location)
            await fetchWeather(location)
        }
    }

    private func reverseGeocode(_ location: CLLocation) async {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return }
        let city  = placemark.locality           ?? ""
        let state = placemark.administrativeArea ?? ""
        let zip   = placemark.postalCode         ?? ""
        let result = [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
        // Only write if changed — prevents redundant @Observable notifications
        if result != cityState   { cityState   = result }
        if zip    != postalCode  { postalCode  = zip    }
    }

    private func fetchWeather(_ location: CLLocation) async {
        // Backoff: after a WeatherKit JWT failure (Code=2) skip retries for 5 minutes.
        // Without this, the system retries continuously and floods @Observable state,
        // forcing every observing view to re-render every few seconds.
        if let lastFailure = weatherFailureDate,
           Date().timeIntervalSince(lastFailure) < Self.weatherRetryInterval { return }

        do {
            let weather = try await WeatherService.shared.weather(for: location)
            let celsius = weather.currentWeather.temperature.value
            let newTemp = celsius * 9.0 / 5.0 + 32.0
            let newCond = weather.currentWeather.condition.description

            weatherFailureDate = nil  // reset on success
            // Only write if changed
            if temperatureFahrenheit != newTemp { temperatureFahrenheit = newTemp }
            if weatherCondition != newCond      { weatherCondition = newCond }
        } catch {
            // Record failure time; suppress all state mutation so the UI doesn't flash
            weatherFailureDate = Date()
        }
    }
}

// MARK: – CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // Stop immediately — one-and-done snapshot. Called nonisolated so it
        // takes effect before any MainActor hop, eliminating GPS jitter updates.
        manager.stopUpdatingLocation()
        Task { @MainActor in
            self.handleNewLocation(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Location unavailable — keep last known value; no state change → no re-render
    }
}

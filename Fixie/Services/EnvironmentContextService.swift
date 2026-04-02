// Services/EnvironmentContextService.swift
// WeatherKit + CoreLocation — fetches current temperature and emits
// contextual safety warnings before the user begins a repair.
import Foundation
import CoreLocation
import WeatherKit

// MARK: – Warning model

struct EnvironmentWarning: Identifiable, Sendable {
    enum Severity: Sendable { case info, caution, emergency }

    let id = UUID()
    let severity: Severity
    let headline: String
    let body: String
    let systemImage: String
}

// MARK: – Service

@Observable @MainActor
final class EnvironmentContextService: NSObject {

    static let shared = EnvironmentContextService()

    // MARK: Published state
    private(set) var currentTempCelsius: Double?
    private(set) var warnings: [EnvironmentWarning] = []
    private(set) var isFetching = false
    private(set) var locationDenied = false

    // MARK: Private
    private let weatherService = WeatherService.shared
    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // MARK: – Public API

    /// Fetches current conditions and populates `warnings` for the given category.
    func refresh(for category: RepairCategory) async {
        isFetching = true
        defer { isFetching = false }

        do {
            let location = try await requestLocation()
            let weather  = try await weatherService.weather(for: location)
            let tempC    = weather.currentWeather.temperature.converted(to: .celsius).value
            currentTempCelsius = tempC
            warnings = buildWarnings(tempCelsius: tempC, category: category)
        } catch {
            // Location or WeatherKit failure — clear warnings silently
            warnings = []
        }
    }

    // MARK: – Warning logic

    private func buildWarnings(tempCelsius: Double, category: RepairCategory) -> [EnvironmentWarning] {
        var result: [EnvironmentWarning] = []

        // Emergency: HVAC / Water Heater + sub-freezing
        if tempCelsius < 0 &&
           (category == .majorAppliances || category == .homeSystems) {
            result.append(EnvironmentWarning(
                severity: .emergency,
                headline: "⚠️ Pipe Freeze Risk",
                body: "Outside temperature is \(formatted(tempCelsius))°C (\(formatted(toFahrenheit(tempCelsius)))°F). "
                    + "Exterior pipes may freeze while the system is offline. "
                    + "Keep the repair window as short as possible and insulate any exposed pipes before starting.",
                systemImage: "thermometer.snowflake"
            ))
        }

        // Caution: near-freezing (< 2°C)
        if tempCelsius < 2 && tempCelsius >= 0 {
            result.append(EnvironmentWarning(
                severity: .caution,
                headline: "Cold Weather Caution",
                body: "Temperature is near freezing (\(formatted(tempCelsius))°C). "
                    + "Plastic components and rubber gaskets become brittle in cold. "
                    + "Work indoors or warm the work area before beginning.",
                systemImage: "thermometer.low"
            ))
        }

        // Caution: plastic brittleness < 5°C
        if tempCelsius < 5 && tempCelsius >= 2 {
            result.append(EnvironmentWarning(
                severity: .info,
                headline: "Low Temperature",
                body: "At \(formatted(tempCelsius))°C plastic clips and seals are stiffer than normal. "
                    + "Apply gentle pressure and allow parts to warm before forcing them.",
                systemImage: "thermometer"
            ))
        }

        // Caution: heat advisory > 38°C
        if tempCelsius > 38 {
            result.append(EnvironmentWarning(
                severity: .caution,
                headline: "Heat Advisory",
                body: "Temperature is \(formatted(tempCelsius))°C (\(formatted(toFahrenheit(tempCelsius)))°F). "
                    + "Take regular breaks, stay hydrated, and avoid working in direct sunlight. "
                    + "Postpone if you are experiencing heat stress.",
                systemImage: "thermometer.sun.fill"
            ))
        }

        return result
    }

    // MARK: – Helpers

    private func formatted(_ c: Double) -> String { String(format: "%.1f", c) }
    private func toFahrenheit(_ c: Double) -> Double { c * 9 / 5 + 32 }

    // MARK: – Location

    private func requestLocation() async throws -> CLLocation {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            // Wait for authorization change, then request location
        case .denied, .restricted:
            locationDenied = true
            throw CLError(.denied)
        default:
            break
        }

        return try await withCheckedThrowingContinuation { cont in
            locationContinuation = cont
            locationManager.requestLocation()
        }
    }
}

// MARK: – CLLocationManagerDelegate

extension EnvironmentContextService: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        Task { @MainActor [weak self] in
            self?.locationContinuation?.resume(returning: loc)
            self?.locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.locationContinuation?.resume(throwing: error)
            self?.locationContinuation = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                self.locationDenied = true
                self.locationContinuation?.resume(throwing: CLError(.denied))
                self.locationContinuation = nil
            } else if manager.authorizationStatus == .authorizedWhenInUse ||
                        manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
}

// Services/VisionObjectIdentifier.swift
// On-device object identification using Apple Vision Framework.
// Runs instantly on the captured image before the backend call so the UI
// can display "Detected: Robot Vacuum" while the network round-trip is in flight.
import Vision
import UIKit

struct VisionObjectIdentifier: Sendable {

    // MARK: – Public API

    /// Identifies the primary object in the image.
    ///
    /// Strategy:
    /// - OCR (VNRecognizeTextRequest) extracts brand names printed on the device — reliable.
    /// - Classification (VNClassifyImageRequest) is only trusted at very high confidence (≥0.80)
    ///   because it frequently misidentifies objects out of repair context (e.g. a white round
    ///   robot vacuum on a tiled floor → "toilet seat").
    ///
    /// Returns a short string like "Yeedi", "Yeedi Robot Vacuum", "Washing Machine".
    /// Returns "" when neither signal is confident enough — Gemini handles naming instead.
    static func identify(imageData: Data) async -> String {
        await identifyDetailed(imageData: imageData).combined
    }

    /// Like `identify`, but also returns the raw OCR brand string (e.g. "tineco") separately.
    /// The `ocrBrand` is passed to `ProductIdentificationService` as a hint for AI reconciliation.
    static func identifyDetailed(imageData: Data) async -> (combined: String, ocrBrand: String) {
        guard let cgImage = UIImage(data: imageData)?.cgImage else { return ("", "") }

        // Run both concurrently.
        async let categoryName = classify(image: cgImage)
        async let brandText    = recognizeText(in: cgImage)

        let (category, brand) = await (categoryName, brandText)

        let combined: String
        if !brand.isEmpty && !category.isEmpty {
            let titleCased = brand.prefix(1).uppercased() + brand.dropFirst()
            combined = "\(titleCased) \(category)"
        } else if !brand.isEmpty {
            combined = brand.prefix(1).uppercased() + brand.dropFirst()
        } else {
            combined = category
        }
        return (combined, brand)
    }

    // MARK: – VNClassifyImageRequest

    private static func classify(image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNClassifyImageRequest { req, error in
                guard error == nil,
                      let results = req.results as? [VNClassificationObservation]
                else {
                    continuation.resume(returning: "")
                    return
                }
                // Two-tier strategy:
                //   Tier 1 (≥0.40) — accept ONLY if the identifier maps to our taxonomyMap.
                //     Our map covers repair-relevant devices; non-repair items (toilet_seat,
                //     chair, carpet, etc.) are NOT in the map and are safely skipped.
                //   Tier 2 (≥0.80) — checked implicitly via Tier 1 at lower threshold.
                //     No raw-identifier fallback: prevents out-of-context names.
                for obs in results where obs.confidence > 0.40 {
                    let name = humanReadable(identifier: obs.identifier)
                    if !name.isEmpty {
                        continuation.resume(returning: name)
                        return
                    }
                }
                // No mapped item found — return "" so OCR brand or Gemini takes over.
                continuation.resume(returning: "")
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: – VNRecognizeTextRequest (brand/model OCR)

    private static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, error in
                guard error == nil,
                      let results = req.results as? [VNRecognizedTextObservation]
                else {
                    continuation.resume(returning: "")
                    return
                }
                // Collect candidates: (text, distance from image center).
                // Prefer text near the CENTER of the frame — that's the main subject.
                // Prefer LONGER strings over shorter when distances are similar —
                // "tineco" (6 chars, center) beats "RYOE" (4 chars, left edge).
                // A partial read of an edge label ("RYOE" from "RYOBI") is both shorter
                // and further from center, so it loses on both criteria.
                let excluded: Set<String> = ["the", "and", "for", "with", "not", "use",
                                              "pro", "max", "plus", "ultra", "model"]
                let imageCenter = CGPoint(x: 0.5, y: 0.5)   // normalized Vision coords

                let ranked = results.compactMap { obs -> (String, CGFloat)? in
                    guard let c = obs.topCandidates(1).first, c.confidence > 0.5 else { return nil }
                    let text = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.count >= 3,
                          !text.allSatisfy({ $0.isNumber || $0.isPunctuation }),
                          !excluded.contains(text.lowercased()) else { return nil }
                    // Distance from image center (Vision bounding box is bottom-left origin, 0-1 normalized)
                    let dist = hypot(obs.boundingBox.midX - imageCenter.x,
                                     obs.boundingBox.midY - imageCenter.y)
                    return (text, dist)
                }
                .sorted { a, b in
                    // Primary: text closer to image center wins (main subject vs edge objects)
                    if abs(a.1 - b.1) > 0.12 { return a.1 < b.1 }
                    // Tiebreak: longer text = more likely a complete brand name, not a partial read
                    return a.0.count > b.0.count
                }

                let brand = ranked.first?.0 ?? ""
                continuation.resume(returning: brand)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.01   // 0.02 was too aggressive — missed Dyson, Shark, etc.
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: – Apple Vision taxonomy → repair-context name

    // Apple Vision returns dot/underscore-separated taxonomy identifiers.
    // We map the ones relevant to home repair into friendly names.
    // Unmapped identifiers fall through to titleCase().
    private static let taxonomyMap: [String: String] = [
        // ── Small Household Appliances ──────────────────────────────────────
        "vacuum_cleaner":       "Vacuum Cleaner",
        "robot_vacuum":         "Robot Vacuum",
        "upright_vacuum":       "Upright Vacuum",
        "canister_vacuum":      "Canister Vacuum",
        "washing_machine":      "Washing Machine",
        "clothes_dryer":        "Clothes Dryer",
        "dishwasher":           "Dishwasher",
        "microwave_oven":       "Microwave",
        "toaster":              "Toaster",
        "toaster_oven":         "Toaster Oven",
        "coffee_maker":         "Coffee Maker",
        "espresso_machine":     "Espresso Machine",
        "blender":              "Blender",
        "food_processor":       "Food Processor",
        "stand_mixer":          "Stand Mixer",
        "air_fryer":            "Air Fryer",
        "instant_pot":          "Pressure Cooker",
        "slow_cooker":          "Slow Cooker",
        "rice_cooker":          "Rice Cooker",
        "electric_kettle":      "Electric Kettle",
        "hair_dryer":           "Hair Dryer",
        "blow_dryer":           "Hair Dryer",
        "hair_straightener":    "Hair Straightener",
        "flat_iron":            "Hair Straightener",
        "curling_iron":         "Curling Iron",
        "electric_shaver":      "Electric Shaver",
        "electric_toothbrush":  "Electric Toothbrush",
        "iron":                 "Clothes Iron",
        "steam_iron":           "Steam Iron",
        "clothes_iron":         "Clothes Iron",
        "sewing_machine":       "Sewing Machine",
        "air_purifier":         "Air Purifier",
        "space_heater":         "Space Heater",
        "ceiling_fan":          "Ceiling Fan",
        "exhaust_fan":          "Exhaust Fan",
        // ── Major Appliances ────────────────────────────────────────────────
        "refrigerator":         "Refrigerator",
        "freezer":              "Freezer",
        "oven":                 "Oven",
        "range":                "Stove / Range",
        "cooktop":              "Cooktop",
        "air_conditioner":      "Air Conditioner",
        "window_unit":          "Window AC Unit",
        "dehumidifier":         "Dehumidifier",
        "humidifier":           "Humidifier",
        "fan":                  "Fan",
        // ── Home Systems ────────────────────────────────────────────────────
        "water_heater":         "Water Heater",
        "furnace":              "Furnace",
        "boiler":               "Boiler",
        "thermostat":           "Thermostat",
        "electrical_panel":     "Electrical Panel",
        "smoke_detector":       "Smoke Detector",
        "sump_pump":            "Sump Pump",
        // ── Tech & Electronics ───────────────────────────────────────────────
        "laptop_computer":      "Laptop",
        "desktop_computer":     "Desktop Computer",
        "computer_monitor":     "Monitor",
        "television_set":       "Television",
        "television":           "Television",
        "cellular_telephone":   "Smartphone",
        "mobile_phone":         "Smartphone",
        "tablet_computer":      "Tablet",
        "iphone":               "iPhone",
        "ipad":                 "iPad",
        "macbook":              "MacBook",
        "mac_mini":             "Mac Mini",
        "imac":                 "iMac",
        "game_console":         "Game Console",
        "printer":              "Printer",
        "scanner":              "Scanner",
        "projector":            "Projector",
        "router":               "Wi-Fi Router",
        "modem":                "Modem",
        "network_switch":       "Network Switch",
        "headphones":           "Headphones",
        "earbuds":              "Earbuds",
        "speaker":              "Speaker",
        "smart_speaker":        "Smart Speaker",
        "camera":               "Camera",
        "dslr_camera":          "DSLR Camera",
        "drone":                "Drone",
        // ── Automotive ──────────────────────────────────────────────────────
        "car":                  "Car",
        "automobile":           "Car",
        "motorcycle":           "Motorcycle",
        "tire":                 "Tire",
        "battery_charger":      "Car Battery Charger",
        // ── Yard & Tools ────────────────────────────────────────────────────
        "lawn_mower":           "Lawn Mower",
        "riding_lawn_mower":    "Riding Mower",
        "chainsaw":             "Chainsaw",
        "leaf_blower":          "Leaf Blower",
        "pressure_washer":      "Pressure Washer",
        "generator":            "Generator",
        "drill":                "Power Drill",
        "circular_saw":         "Circular Saw",
        "electric_sander":      "Electric Sander",
        "string_trimmer":       "String Trimmer",
    ]

    private static func humanReadable(identifier: String) -> String {
        // Normalize: replace dots/hyphens/spaces with underscores, lowercase
        let key = identifier
            .lowercased()
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        // Exact match
        if let name = taxonomyMap[key] { return name }

        // Substring match — catches "home.vacuum_cleaner", "apple.laptop_computer", etc.
        if let entry = taxonomyMap.first(where: { key.contains($0.key) || $0.key.contains(key) }) {
            return entry.value
        }

        // Skip generic non-informative identifiers (Apple Vision's fallback categories)
        let generic: Set<String> = [
            "device", "object", "thing", "item", "product", "equipment",
            "appliance", "home_appliance", "electronics", "technology",
            "indoor", "indoor_scene", "no_person", "still_life"
        ]
        if generic.contains(key) { return "" }

        return ""   // Unknown → caller uses titleCase of raw identifier as last resort
    }

    private static func titleCase(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}

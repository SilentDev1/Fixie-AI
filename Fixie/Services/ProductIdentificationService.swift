// Services/ProductIdentificationService.swift
// Runs Gemini + GPT-4o concurrently to identify the specific product/device in a photo
// before passing to the Replit backend. Corrects Apple Vision misclassifications
// (e.g. Tineco floor cleaner → "Washing Machine", cylindrical appliances → wrong category).
import Foundation

struct ProductIdentificationService: Sendable {

    /// Asks Gemini and GPT-4o concurrently to identify the product in the image.
    ///
    /// - `imageData`: compressed JPEG (512px / 0.7q is fine — same as Vision input).
    /// - `ocrBrand`: raw OCR brand text from Apple Vision (e.g. "tineco") — used as a
    ///   tiebreaker when the two models disagree.
    ///
    /// Returns a clean product name like "Tineco Floor One S5 Combo", or "" when both fail.
    /// On failure the caller keeps the existing Apple Vision result unchanged.
    static func identify(imageData: Data, ocrBrand: String) async -> String {
        async let geminiResult = gemini(imageData: imageData, ocrBrand: ocrBrand)
        async let openAIResult = openAI(imageData: imageData, ocrBrand: ocrBrand)
        let (g, o) = await (geminiResult, openAIResult)
        let winner = reconcile(gemini: g, openai: o, ocrBrand: ocrBrand)
        if !winner.isEmpty {
            print("[Fixie] 🤖 ProductID → Gemini: \"\(g)\" | GPT: \"\(o)\" → using: \"\(winner)\"")
        }
        return winner
    }

    // MARK: – Individual callers

    private static func gemini(imageData: Data, ocrBrand: String) async -> String {
        await GeminiService.shared.identifyProduct(imageData: imageData, ocrBrand: ocrBrand)
    }

    private static func openAI(imageData: Data, ocrBrand: String) async -> String {
        await OpenAIService.shared.identifyProduct(imageData: imageData, ocrBrand: ocrBrand)
    }

    // MARK: – Reconciliation

    private static func reconcile(gemini: String, openai: String, ocrBrand: String) -> String {
        let g = sanitize(gemini)
        let o = sanitize(openai)

        // Both empty — nothing identified
        if g.isEmpty && o.isEmpty { return "" }
        // One empty — use the other
        if g.isEmpty { return o }
        if o.isEmpty { return g }

        let brand = ocrBrand.lowercased()

        // If we have an OCR brand hint, prefer the answer that contains it
        if !brand.isEmpty {
            let gHasBrand = g.lowercased().contains(brand)
            let oHasBrand = o.lowercased().contains(brand)
            if  gHasBrand && !oHasBrand { return g }
            if !gHasBrand &&  oHasBrand { return o }
            // Both contain brand — use the longer (more specific model name)
            if  gHasBrand &&  oHasBrand { return g.count >= o.count ? g : o }
        }

        // No OCR hint or neither matched — do the models agree (share ≥1 word ≥4 chars)?
        let gWords = Set(g.lowercased().components(separatedBy: " ").filter { $0.count >= 4 })
        let oWords = Set(o.lowercased().components(separatedBy: " ").filter { $0.count >= 4 })
        if !gWords.intersection(oWords).isEmpty {
            // Consensus — use the longer (more specific) answer
            return g.count >= o.count ? g : o
        }

        // Disagreement and no OCR hint — default to Gemini (primary model)
        return g
    }

    /// Strips LLM filler text; returns "" when the result looks like an explanation, not a name.
    private static func sanitize(_ raw: String) -> String {
        var s = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        // Strip common LLM padding prefixes (case-insensitive)
        let prefixes = ["the product is ", "this is a ", "this is an ",
                        "i see a ", "i see an ", "it appears to be a ",
                        "it appears to be an ", "the device is "]
        for prefix in prefixes where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Very long strings are explanations, not product names — discard
        if s.count > 60 { return "" }
        return s
    }
}

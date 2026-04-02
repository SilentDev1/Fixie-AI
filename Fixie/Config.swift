// Config.swift
import Foundation

enum Config {
    // MARK: – Gemini
    /// Set GEMINI_API_KEY in the Xcode scheme environment, or replace the fallback string.
    static let geminiAPIKey: String = {
        ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
    }()

    /// Gemini model identifier.
    static let geminiModel = "gemini-2.5-flash"
    static let geminiBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!

    // MARK: – OpenAI (backup AI)
    static let openAIAPIKey: String = {
        ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "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"
    }()
    static let openAIModel = "gpt-4o-mini"

    // MARK: – Diagnosis behaviour
    static let frameAnalysisInterval: TimeInterval = 4.0
    static let maxOutputTokens = 4096
    static let lowConfidenceThreshold: Double = 0.55

    // MARK: – Free tier
    /// Max Gemini calls per day before paywall is presented.
    static let freeUsageLimitPerDay = 5

    // MARK: – Amazon Product Advertising API v5
    // Set via scheme environment or replace fallback strings.
    static let amazonAccessKey: String = {
        ProcessInfo.processInfo.environment["AMAZON_ACCESS_KEY"] ?? "YOUR_AMAZON_ACCESS_KEY"
    }()
    static let amazonSecretKey: String = {
        ProcessInfo.processInfo.environment["AMAZON_SECRET_KEY"] ?? "YOUR_AMAZON_SECRET_KEY"
    }()
    /// Your Amazon Associates tracking ID (e.g. "fixie-20").
    static let amazonPartnerTag = "fixie-20"
    static let amazonRegion     = "us-east-1"
    static let amazonHost       = "webservices.amazon.com"
    static let amazonService    = "ProductAdvertisingAPI"

    // MARK: – Backend API
    /// Base URL for the Fixie backend REST API (reschedule, etc.).
    /// Update this when deploying to production.
    static let backendBaseURL = URL(string: "https://fixieai.app/api")!

    // MARK: – Compliance
    static let affiliateDisclaimer = "As an Amazon Associate, Fixie earns from qualifying purchases."
    static let aiDisclosureText    = "Diagnosis powered by Gemini AI. Always verify before beginning repairs."
    static let c2paProducerName    = "Fixie — AI Repair Assistant"
}

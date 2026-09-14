# Fixie

**An AI-powered home & appliance repair assistant for iOS.** Point your camera at something that's
broken — an appliance, fixture, or device — and Fixie identifies it, diagnoses the likely problem,
walks you through a repair with step-by-step guides and the right tools, and, when a job is beyond
DIY, connects you to verified local repair pros.


## What it does

- **Identify & diagnose** — on-device Vision + multimodal AI (Google Gemini via Firebase, with an
  OpenAI path) identify the product from a photo and produce a structured diagnosis.
- **Guided repair** — step-by-step repair guides by category, with tool intelligence and
  recommended parts/tools.
- **Find a pro** — surfaces verified local professionals and turns a stuck repair into an active
  service lead, with reviews and scheduling.
- **History & invoicing** — tracks repair sessions, jobs, and invoices over time.
- **Subscriptions** — StoreKit-based entitlements; Siri/App Intents for hands-free entry.

## Architecture

SwiftUI app with a Firebase backend:

```text
Fixie/
  Models/        Domain models — RepairSession, RepairGuide, Job, Invoice,
                 VerifiedPro, ActiveServiceLead, ContractorReview, …
  Services/      AIManager, DiagnosisEngine, GeminiService / FirebaseGeminiService,
                 OpenAIService, VisionObjectIdentifier, ProductIdentificationService,
                 AuthService, FirebaseService, StoreKitManager, LocationService,
                 CalendarManager, ToolIntelligenceService, LocalProService, …
  ViewModels/    CameraViewModel, HomeViewModel, …
  Views/         Home, Camera, RepairHub, RepairGuide, History, Safety, Shared
  AppIntents/    Siri / App Intents integration
  DesignSystem/  Theme
functions/       Firebase Cloud Functions (Node — firebase-admin, firebase-functions)
firestore.rules, storage.rules, firestore.indexes.json, firebase.json
```

**Stack:** SwiftUI · Swift Concurrency · Apple Vision · Firebase (Auth, Firestore, Cloud Functions) ·
Google Gemini · OpenAI · StoreKit 2 · App Intents · Node.js (Cloud Functions).

## Configuration & security

This app requires several credentials at runtime — a Firebase config, a Gemini/AI key, and an Apple
key. **These must be supplied via secure configuration, never committed to source control:**

- Provide API keys through Xcode build settings / environment or a secrets manager, not hardcoded.
- Keep `GoogleService-Info.plist`, any `*-adminsdk-*.json` service-account key, and `AuthKey_*.p8`
  **out of git** (they belong in `.gitignore` and a secret store).
- Firebase **Admin** service-account keys grant full project access — treat them as highly sensitive
  and rotate immediately if ever exposed.
- `node_modules/` should not be committed — install with `npm ci` in `functions/`.

## Status

Active development (iOS, SwiftUI). This README is a portfolio overview; see
[`docs/PROJECT_WRITEUP.md`](docs/PROJECT_WRITEUP.md) for the design narrative.

## License

See [`LICENSE`](LICENSE) — all rights reserved; published for portfolio review only.

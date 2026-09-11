# Fixie — Project Writeup

## The idea

Most people, faced with a broken appliance or fixture, don't know what it is, what's wrong, whether
it's fixable themselves, or who to call. The information exists — repair guides, part numbers, local
pros — but it's fragmented and intimidating. Fixie compresses that into one flow on your phone:
**photo → identification → diagnosis → guided fix or the right pro.**

## The experience

1. **See it.** The camera + Apple Vision + a multimodal model (Gemini via Firebase, OpenAI as an
   alternate path) identify the product and its likely failure mode from an image and context.
2. **Understand it.** A diagnosis engine turns that into a structured, plain-language explanation:
   what's wrong, how hard the fix is, what it needs.
3. **Fix it.** Category-based repair guides walk through the steps, with tool intelligence and
   recommended parts.
4. **Or hand it off.** When it's beyond DIY, Fixie converts the session into an *active service lead*
   and surfaces verified local pros with reviews and scheduling.
5. **Keep a record.** Repair sessions, jobs, and invoices are tracked over time.

## Engineering notes

- **SwiftUI + Swift Concurrency**, structured into Models / Services / ViewModels / Views, with a
  design-system theme layer — a clean separation that keeps the AI/camera complexity out of the views.
- **Pluggable AI layer.** `AIManager` + `DiagnosisEngine` sit in front of interchangeable providers
  (`FirebaseGeminiService`, `GeminiService`, `OpenAIService`) and on-device `VisionObjectIdentifier`
  / `ProductIdentificationService`, so the model backend can change without touching the UI.
- **Firebase backend** for auth, data (Firestore with rules + indexes), and Cloud Functions, plus
  StoreKit 2 for subscriptions and App Intents for Siri entry.
- **Real-world services** — location, calendar, media, network monitoring, tool/product
  identification — wired as discrete services.

## What this demonstrates

- Shipping a **multimodal, camera-driven AI feature** end-to-end on iOS, not just a chat wrapper.
- Clean SwiftUI architecture with a **provider-agnostic AI abstraction**.
- Integrating a full **Firebase backend** (auth, Firestore, Functions), payments (StoreKit), and
  system integrations (Vision, App Intents, Location, Calendar).

## A note on security (and a lesson)

An early version of this repo committed live credentials (a Firebase Admin service-account key, an
Apple key, and AI API keys) and a checked-in `node_modules/`. That's a common but serious mistake:
secrets in git history are effectively leaked. The correct handling — adopted here — is to keep all
keys in secure configuration / a secrets manager, `.gitignore` them and dependency directories, and
**rotate any credential that ever touched the repo**. Publishing this project requires that cleanup
first; it's tracked before the repo goes public.

## Status

Active iOS development. This writeup is a portfolio overview of the design; the app is not a finished
commercial release.

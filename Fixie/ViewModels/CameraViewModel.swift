// ViewModels/CameraViewModel.swift
// @MainActor — only UI state lives here.
// All AVFoundation work delegated to CameraActor.
import AVFoundation
import SwiftUI
import Observation

// MARK: – Phase state machine

enum CameraPhase: Equatable {
    case idle
    case requestingPermission
    case scanning
    case capturing
    case analyzing(String)
    case done(RepairGuide)
    case toolCheck(ToolCheckResult)
    case error(String)

    static func == (lhs: CameraPhase, rhs: CameraPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.scanning, .scanning),
             (.capturing, .capturing), (.requestingPermission, .requestingPermission):
            return true
        case (.analyzing(let a), .analyzing(let b)): return a == b
        case (.error(let a), .error(let b)):          return a == b
        case (.done, .done), (.toolCheck, .toolCheck): return true
        default: return false
        }
    }
}

// MARK: – ViewModel

@Observable
@MainActor
final class CameraViewModel {

    // MARK: UI state
    var phase: CameraPhase = .idle
    var isListenMode        = false
    var category: RepairCategory?
    var capturedImage: UIImage?
    var hintText            = "Point camera at the appliance or equipment"
    /// Optional free-text description the user typed before opening the camera.
    /// Sent alongside the image in the backend /diagnose request.
    var userDescription: String = ""
    /// Set by VisionObjectIdentifier immediately after shutter press.
    /// Displayed in the top bar before the backend responds and sent in the API payload.
    var detectedItemName: String = ""

    // MARK: Actor (send-isolated AVFoundation)
    let camera = CameraActor()

    // Expose session for CameraPreviewView and for the runtime error monitor
    nonisolated var captureSession: AVCaptureSession { camera.session }

    // MARK: Services
    private let engine = DiagnosisEngine()

    // Track the main session task so it can be cancelled on stop()
    private var sessionTask: Task<Void, Never>?

    // Pending tool-check tools list
    private var pendingToolCheckTools: [String]?

    // Audio accumulation
    private var audioTask: Task<Void, Never>?
    private var audioChunks: [Data] = []
    private var audioFormat: AVAudioFormat?

    // MARK: – Lifecycle

    func requestAndStart() {
        // Guard re-entry: onAppear can fire again when the parent view re-renders
        // due to @Observable state changes (LocationService, AuthService).
        guard phase == .idle else { return }

        #if targetEnvironment(simulator)
        // The iOS Simulator has no real camera XPC service. Attempting to start
        // AVCaptureSession causes err=-17281 (FigCaptureSourceRemote XPC failure)
        // which loops until we stop the session. Skip setup entirely and show a
        // clear placeholder — zero XPC errors on Simulator.
        phase = .error("Camera is not available in the Simulator.\nRun on a physical iPhone to use Fixie's camera features.")
        return
        #endif

        // Belt-and-suspenders: if the hardware session is already running
        // (e.g. view reappeared while a prior start was in-flight), don't restart it.
        guard !captureSession.isRunning else {
            phase = .scanning
            return
        }

        phase = .requestingPermission

        sessionTask = Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                phase = .error("Camera access denied. Enable it in Settings → Privacy → Camera.")
                return
            }
            await camera.configure()
            await camera.startSession()
            phase = .scanning
            // Pre-warm the backend while the user frames their shot.
            FixieBackendService.shared.warmUp()

            // Monitor for AVFoundation runtime errors. On first error stop the
            // session immediately to prevent AVFoundation's reconnect loop.
            await monitorSessionErrors()
        }
    }

    func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        audioTask?.cancel()
        audioTask = nil
        Task { await camera.stopAudioCapture(); await camera.stopSession() }
    }

    // MARK: – Runtime error monitor

    /// Suspends until AVFoundation fires AVCaptureSessionRuntimeError, then stops
    /// the session and transitions to an error phase. Exits cleanly on task cancellation.
    private func monitorSessionErrors() async {
        let stream = NotificationCenter.default.notifications(
            named: AVCaptureSession.runtimeErrorNotification,
            object: captureSession
        )
        for await notification in stream {
            guard !Task.isCancelled else { return }
            // Stop the session immediately — prevents the continuous XPC retry loop
            await camera.stopSession()
            let errorDesc = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?
                .localizedDescription
            phase = .error(
                errorDesc ?? "Camera hardware unavailable. Use a physical iPhone for full camera features."
            )
            return  // Handle first error only
        }
    }

    // MARK: – Photo capture

    func capturePhoto() {
        guard case .scanning = phase else { return }
        phase = .capturing
        hintText = "Capturing…"
        Task { await performCapture() }
    }

    private func performCapture() async {
        do {
            let rawData = try await camera.capturePhoto()
            guard let image = UIImage(data: rawData) else {
                phase = .error("Could not decode captured image.")
                return
            }
            capturedImage = image

            // ── On-device Vision identification (instant, runs before backend) ──
            // Identifies the object type and visible brand text so we can show
            // "Detected: Yeedi Robot Vacuum" immediately in the UI while the
            // network call is in flight.  Downsample to 512px — classification
            // doesn't need full resolution and runs faster at smaller size.
            let visionData: Data = {
                guard let img = UIImage(data: rawData) else { return rawData }
                let side = max(img.size.width, img.size.height)
                let scale = side > 512 ? 512 / side : 1.0
                let size = CGSize(width: (img.size.width * scale).rounded(),
                                  height: (img.size.height * scale).rounded())
                let renderer = UIGraphicsImageRenderer(size: size)
                let small = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
                return small.jpegData(compressionQuality: 0.7) ?? rawData
            }()
            let (visionName, ocrBrand) = await VisionObjectIdentifier.identifyDetailed(imageData: visionData)
            if !visionName.isEmpty {
                detectedItemName = visionName
                hintText = "Detected: \(visionName)"
            }

            if let tools = pendingToolCheckTools {
                pendingToolCheckTools = nil
                phase = .analyzing("Checking your tools…")
                let result = try await engine.checkTools(imageData: rawData, requiredTools: tools)
                phase = .toolCheck(result)
            } else {
                // Dual-AI product identification (Gemini + GPT-4o concurrently).
                // Runs before the backend diagnose call so the corrected name travels with the payload.
                // Fixes Vision misclassifications (e.g. Tineco floor cleaner → "Washing Machine").
                phase = .analyzing("Identifying product…")
                let aiName = await ProductIdentificationService.identify(imageData: visionData, ocrBrand: ocrBrand)
                if !aiName.isEmpty {
                    detectedItemName = aiName
                    hintText = "Detected: \(aiName)"
                }

                hintText = "Identifying brand → model → symptom → failures…"
                for try await event in engine.diagnoseStream(
                    imageData:         rawData,
                    category:          category,
                    userDescription:   userDescription,
                    detectedItemName:  detectedItemName
                ) {
                    switch event {
                    case .status(let text):
                        phase = .analyzing(text)
                    case .detectedItem(let name):
                        // Backend identified the device before full payload — update header now.
                        if !name.isEmpty && detectedItemName.isEmpty {
                            detectedItemName = name
                            hintText = "Detected: \(name)"
                        }
                    case .guide(let guide):
                        phase = .done(guide)
                    }
                }
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: – Listen mode

    func toggleListenMode() {
        isListenMode.toggle()
        if isListenMode {
            startAudio()
        } else {
            stopAudio()
        }
    }

    private func startAudio() {
        audioChunks = []
        audioFormat = nil
        hintText = "Listening for mechanical sounds…"
        audioTask = Task {
            do {
                let stream = try await camera.startAudioCapture()
                // Capture the format immediately after the stream is created.
                audioFormat = await camera.lastAudioFormat
                for try await chunk in stream {
                    audioChunks.append(chunk)
                }
            } catch {
                if !Task.isCancelled {
                    phase = .error("Microphone error: \(error.localizedDescription)")
                    isListenMode = false
                }
            }
        }
    }

    private func stopAudio() {
        audioTask?.cancel()
        audioTask = nil
        Task { await camera.stopAudioCapture() }
    }

    func submitAudioDiagnosis() {
        guard isListenMode, !audioChunks.isEmpty else { return }
        stopAudio()
        isListenMode = false

        let combined = audioChunks.reduce(Data(), +)
        let cat      = category ?? .majorAppliances
        let fmt      = audioFormat
        phase = .analyzing("Analyzing sound…")

        Task {
            do {
                let guide = try await engine.diagnoseAudio(audioData: combined, audioFormat: fmt, category: cat)
                phase = .done(guide)
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    // MARK: – Tool check

    func initiateToolCheck(requiredTools: [String]) {
        pendingToolCheckTools = requiredTools
        hintText = "Lay your tools flat — then tap capture"
        phase = .scanning
    }

    // MARK: – Reset

    func reset() {
        phase = .scanning
        capturedImage = nil
        hintText = "Point camera at the appliance or equipment"
        pendingToolCheckTools = nil
    }
}

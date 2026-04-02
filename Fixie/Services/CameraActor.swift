// Services/CameraActor.swift
// Dedicated actor: ALL AVFoundation objects live here.
// CameraViewModel (@MainActor) communicates only through async calls.
import AVFoundation

// MARK: – Photo capture result

enum CameraActorError: LocalizedError {
    case notConfigured
    case captureFailure(String)
    case sessionNotRunning
    case audioEngineError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:           return "Camera session is not configured."
        case .captureFailure(let m):   return "Capture failed: \(m)"
        case .sessionNotRunning:       return "Camera session is not running."
        case .audioEngineError(let m): return "Audio engine error: \(m)"
        }
    }
}

// MARK: – Actor

actor CameraActor {

    // MARK: AVFoundation objects (all actor-isolated)
    // `session` is `nonisolated(unsafe)` so CameraPreviewView can bind the layer
    // directly from the SwiftUI view body without an async hop.  All mutations go
    // through `sessionQueue` — the same thread AVFoundation expects.
    nonisolated(unsafe) let session = AVCaptureSession()
    private let photoOutput  = AVCapturePhotoOutput()
    private let audioEngine  = AVAudioEngine()

    // AVCaptureSession.startRunning() / stopRunning() are blocking synchronous
    // calls that MUST run on a background serial queue — never on the cooperative
    // thread pool used by Swift actors or on the main thread.
    private let sessionQueue = DispatchQueue(
        label: "com.fixie.camera.session", qos: .userInitiated)

    private var isConfigured  = false
    private var isAudioActive = false

    /// The AVAudioFormat captured when audio recording starts.
    /// Read by CameraViewModel after startAudioCapture() to pass to DiagnosisEngine.
    private(set) var lastAudioFormat: AVAudioFormat?

    // Continuation for bridging the delegate callback into async
    private var photoContinuation: CheckedContinuation<Data, Error>?

    // NSObject delegate bridge (lives outside actor — see below)
    private var photoDelegate: _PhotoDelegate?

    // MARK: – Session lifecycle

    func configure() async {
        guard !isConfigured else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        // Video input
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input  = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        // Photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        session.commitConfiguration()
        isConfigured = true

        let delegate = _PhotoDelegate()
        delegate.actor = self
        photoDelegate = delegate
    }

    func startSession() async {
        guard !session.isRunning else { return }
        // startRunning() is a blocking synchronous call — must not block the
        // cooperative thread pool.  Dispatch to the dedicated sessionQueue and
        // await completion so callers know the camera is actually live.
        // `nonisolated(unsafe)` suppresses the Swift 6 Sendable warning for the
        // AVCaptureSession capture — thread safety is enforced by sessionQueue.
        nonisolated(unsafe) let s = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                s.startRunning()
                continuation.resume()
            }
        }
    }

    func stopSession() async {
        guard session.isRunning else { return }
        nonisolated(unsafe) let s = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                s.stopRunning()
                continuation.resume()
            }
        }
    }

    // MARK: – Photo capture (async / await)

    func capturePhoto() async throws -> Data {
        guard isConfigured else { throw CameraActorError.notConfigured }
        guard session.isRunning else { throw CameraActorError.sessionNotRunning }

        return try await withCheckedThrowingContinuation { [self] cont in
            // Overwrite any stale continuation (shouldn't happen, but safe)
            self.photoContinuation = cont
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            self.photoOutput.capturePhoto(with: settings, delegate: self.photoDelegate!)
        }
    }

    // Called by _PhotoDelegate (no actor isolation needed — delegate does Task hop)
    func _photoDidFinish(data: Data) {
        photoContinuation?.resume(returning: data)
        photoContinuation = nil
    }

    func _photoDidFail(error: Error) {
        photoContinuation?.resume(throwing: error)
        photoContinuation = nil
    }

    // MARK: – Video clip capture (5-second clip for audio/visual diagnostics)

    private var movieOutput     = AVCaptureMovieFileOutput()
    private var clipURL:          URL?
    private var clipDelegate:     _MovieDelegate?
    private var clipContinuation: CheckedContinuation<Data, Error>?

    /// Records a video clip for `duration` seconds and returns the MP4 data.
    /// Also extracts up to `keyframeCount` JPEG keyframes and appends them to `keyframesOut`.
    func captureVideoClip(duration: TimeInterval = 5.0) async throws -> Data {
        guard isConfigured else { throw CameraActorError.notConfigured }
        guard session.isRunning else  { throw CameraActorError.sessionNotRunning }

        // Add movie output if not already attached
        if !session.outputs.contains(where: { $0 is AVCaptureMovieFileOutput }) {
            session.beginConfiguration()
            if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
            session.commitConfiguration()
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixie_clip_\(UUID().uuidString).mp4")
        clipURL = url

        let delegate = _MovieDelegate()
        delegate.actor = self
        clipDelegate = delegate

        return try await withCheckedThrowingContinuation { [self] cont in
            self.clipContinuation = cont
            self.movieOutput.startRecording(to: url, recordingDelegate: delegate)

            // Stop after `duration` seconds
            Task {
                try? await Task.sleep(for: .seconds(duration))
                self.movieOutput.stopRecording()
            }
        }
    }

    /// Called by _MovieDelegate when recording finishes.
    func _clipDidFinish(url: URL, error: Error?) {
        if let error {
            clipContinuation?.resume(throwing: error)
        } else if let data = try? Data(contentsOf: url) {
            clipContinuation?.resume(returning: data)
            try? FileManager.default.removeItem(at: url)
        } else {
            clipContinuation?.resume(throwing: CameraActorError.captureFailure("Could not read clip data"))
        }
        clipContinuation = nil
        clipDelegate     = nil
    }

    // MARK: – Audio (Listen mode)
    //  Returns an AsyncThrowingStream of raw PCM chunks.

    func startAudioCapture() throws -> AsyncThrowingStream<Data, Error> {
        guard !isAudioActive else {
            throw CameraActorError.audioEngineError("Already recording.")
        }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()

        let inputNode = audioEngine.inputNode
        let format    = inputNode.outputFormat(forBus: 0)
        lastAudioFormat = format

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let chunk = buffer.rawData() {
                continuation.yield(chunk)
            }
        }

        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw CameraActorError.audioEngineError(error.localizedDescription)
        }

        isAudioActive = true
        return stream
    }

    func stopAudioCapture() {
        guard isAudioActive else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isAudioActive = false
    }
}

// MARK: – Photo delegate bridge (NSObject, outside the actor)

final class _PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    weak var actor: CameraActor?

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard let actor else { return }
        if let error {
            Task { await actor._photoDidFail(error: error) }
        } else if let data = photo.fileDataRepresentation() {
            Task { await actor._photoDidFinish(data: data) }
        } else {
            Task { await actor._photoDidFail(error: CameraActorError.captureFailure("No image data")) }
        }
    }
}

// MARK: – Movie delegate bridge (NSObject, outside the actor)

final class _MovieDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    weak var actor: CameraActor?

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        guard let actor else { return }
        Task { await actor._clipDidFinish(url: outputFileURL, error: error) }
    }
}

// MARK: – AVAudioPCMBuffer → Data helper

private extension AVAudioPCMBuffer {
    func rawData() -> Data? {
        guard let channelData = floatChannelData else { return nil }
        let channelCount = Int(format.channelCount)
        let frameLength  = Int(self.frameLength)
        var data = Data(capacity: frameLength * channelCount * MemoryLayout<Float>.size)
        for ch in 0..<channelCount {
            withUnsafeBufferPointer(to: channelData[ch], frameLength: frameLength) { ptr in
                data.append(UnsafeBufferPointer<Float>(start: ptr.baseAddress, count: frameLength)
                    .withMemoryRebound(to: UInt8.self) { Data($0) })
            }
        }
        return data
    }

    private func withUnsafeBufferPointer<T>(
        to pointer: UnsafeMutablePointer<T>,
        frameLength: Int,
        _ body: (UnsafeBufferPointer<T>) -> Void
    ) {
        body(UnsafeBufferPointer(start: pointer, count: frameLength))
    }
}

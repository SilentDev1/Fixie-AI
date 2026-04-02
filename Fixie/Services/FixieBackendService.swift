// Services/FixieBackendService.swift
// Routes AI diagnosis calls through the Fixie backend (https://fixieai.app/api/diagnose).
// The backend calls Gemini server-side and returns the same JSON schema as
// GeminiDiagnosisPayload, plus an optional `requiresClarification` flag.
//
// DiagnosisEngine tries this service first; any network or HTTP error causes a
// transparent fall-through to the direct Gemini path so the user is never blocked.
import Foundation

final class FixieBackendService: Sendable {

    static let shared = FixieBackendService()
    private init() {}

    private let session = URLSession.shared
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: – Request / Response wire types

    private struct DiagnoseRequest: Encodable {
        let imageBase64: String
        let mimeType: String
        let category: String
        /// Free-text description the user typed before (or instead of) taking a photo.
        let userDescription: String
        /// Object name identified on-device by Apple Vision before the backend call.
        /// e.g. "Yeedi Robot Vacuum", "iPad", "Washing Machine".
        /// Empty string when Vision did not produce a result.
        let detectedItemName: String
        /// Non-nil on re-diagnose after the user confirms or corrects the device model.
        /// Sent as `confirmed_model` (snake_case) in the request body.
        let confirmedModel: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(imageBase64,     forKey: .imageBase64)
            try c.encode(mimeType,        forKey: .mimeType)
            try c.encode(category,        forKey: .category)
            try c.encode(userDescription, forKey: .userDescription)
            try c.encode(detectedItemName, forKey: .detectedItemName)
            // Omit confirmedModel entirely when nil so legacy servers see no change
            if let m = confirmedModel { try c.encode(m, forKey: .confirmedModel) }
        }
        enum CodingKeys: String, CodingKey {
            case imageBase64, mimeType, category, userDescription, detectedItemName, confirmedModel
        }
    }

    // MARK: – Errors

    enum BackendError: LocalizedError {
        case notDeployed          // 404 / connection refused — backend not up yet
        case httpError(Int)
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .notDeployed:        return "Could not reach the Fixie server. Please check your connection and try again."
            case .httpError(let c):   return "Backend HTTP \(c)."
            case .parseError(let m):  return "Backend parse error: \(m)"
            }
        }
    }

    // MARK: – Diagnose

    /// Sends the image to the Fixie backend.  Returns `GeminiDiagnosisPayload` on success.
    /// Throws `BackendError.notDeployed` when the server is unreachable so callers can fall back.
    func diagnose(imageData: Data,
                  mimeType: String = "image/jpeg",
                  category: RepairCategory? = nil,
                  userDescription: String = "",
                  detectedItemName: String = "",
                  confirmedModel: String? = nil) async throws -> GeminiDiagnosisPayload {

        let url = Config.backendBaseURL.appendingPathComponent("diagnose")

        let body = DiagnoseRequest(
            imageBase64:      imageData.base64EncodedString(),
            mimeType:         mimeType,
            category:         category?.rawValue ?? "",
            userDescription:  userDescription,
            detectedItemName: detectedItemName,
            confirmedModel:   confirmedModel
        )

        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Server expects snake_case keys (image_base64, mime_type, user_description, category).
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody    = try encoder.encode(body)
        req.timeoutInterval = 120  // 120s: covers cold-start (~5s) + AI processing (~50s) + buffer

        // Attach Firebase Auth ID token when available (optional — backend may also work
        // without auth during development / when using an allow-all rule).
        if let token = await fetchIDToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // URLSession errors (no connectivity, refused connection, DNS failure)
            // → backend is not deployed or unreachable.  Signal caller to fall back.
            throw BackendError.notDeployed
        }

        guard let http = response as? HTTPURLResponse else { throw BackendError.notDeployed }

        // 404 or connection-level errors → server not deployed yet
        if http.statusCode == 404 || http.statusCode == 503 { throw BackendError.notDeployed }

        guard (200...299).contains(http.statusCode) else {
            throw BackendError.httpError(http.statusCode)
        }

        let cleaned = stripFences(String(data: data, encoding: .utf8) ?? "")
        guard let cleanData = cleaned.data(using: .utf8) else {
            throw BackendError.parseError("Could not re-encode response")
        }

        do {
            return try decoder.decode(GeminiDiagnosisPayload.self, from: cleanData)
        } catch {
            // Log the raw body so we can see if the server sent HTML, an error string,
            // or a JSON shape that doesn't match GeminiDiagnosisPayload.
            let preview = String(data: cleanData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(600) ?? "<non-UTF8>"
            print("[Fixie] ❌ Backend parse error — decoder: \(error)")
            print("[Fixie] ❌ Raw response (\(cleanData.count) bytes): \(preview)")
            throw BackendError.parseError(error.localizedDescription)
        }
    }

    // MARK: – Streaming diagnosis (SSE / JSON auto-detect)

    /// Events emitted by `diagnoseStream()`.
    enum BackendStreamEvent: Sendable {
        /// Intermediate status text for progressive UI updates.
        case status(String)
        /// Device name identified by the backend — emitted as soon as the first
        /// SSE event containing `detected_item_name` arrives, before the full payload.
        case detectedItem(String)
        /// Final decoded payload — always the last event.
        case result(GeminiDiagnosisPayload)
    }

    /// Streaming version of `diagnose()`.
    /// — When the backend returns `Content-Type: text/event-stream`, parses SSE events:
    ///     `data: {"type":"status","text":"…"}` → `.status`
    ///     any other complete JSON line → decoded as `.result`
    /// — When the backend returns regular JSON (current state), collects all bytes
    ///   and emits a single `.result` event.  Either way, the caller gets real-time
    ///   status updates while waiting for the final payload.
    func diagnoseStream(imageData: Data,
                        mimeType: String = "image/jpeg",
                        category: RepairCategory? = nil,
                        userDescription: String = "",
                        detectedItemName: String = "") -> AsyncThrowingStream<BackendStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = Config.backendBaseURL.appendingPathComponent("diagnose")
                    let body = DiagnoseRequest(imageBase64:      imageData.base64EncodedString(),
                                               mimeType:         mimeType,
                                               category:         category?.rawValue ?? "",
                                               userDescription:  userDescription,
                                               detectedItemName: detectedItemName,
                                               confirmedModel:   nil)
                    var req = URLRequest(url: url)
                    req.httpMethod  = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    // Signal SSE preference; server falls back to JSON if not supported.
                    req.setValue("text/event-stream, application/json;q=0.9", forHTTPHeaderField: "Accept")
                    let encoder = JSONEncoder()
                    encoder.keyEncodingStrategy = .convertToSnakeCase
                    req.httpBody = try encoder.encode(body)
                    req.timeoutInterval = 120

                    if let token = await fetchIDToken() {
                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }

                    let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (asyncBytes, response) = try await session.bytes(for: req)
                    } catch {
                        continuation.finish(throwing: BackendError.notDeployed); return
                    }

                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: BackendError.notDeployed); return
                    }
                    if http.statusCode == 404 || http.statusCode == 503 {
                        continuation.finish(throwing: BackendError.notDeployed); return
                    }
                    guard (200...299).contains(http.statusCode) else {
                        continuation.finish(throwing: BackendError.httpError(http.statusCode)); return
                    }

                    let ct = http.value(forHTTPHeaderField: "Content-Type") ?? ""

                    if ct.contains("text/event-stream") {
                        // ── SSE mode ───────────────────────────────────────────
                        // Server emits typed events:
                        //   {type:"status", text:"...", detectedCategory:"..."}
                        //   {type:"done", detectedCategory:"...", result:{...payload...}}
                        //   [DONE]  (terminal sentinel)
                        //
                        // detectedCategory is read from EVERY event so the caller can
                        // update the UI category as soon as the AI classifies the device,
                        // even before the full payload arrives.
                        var latestCategory: String? = nil

                        for try await line in asyncBytes.lines {
                            guard line.hasPrefix("data: ") else { continue }
                            let chunk = String(line.dropFirst(6))
                            if chunk == "[DONE]" { break }

                            guard let d = chunk.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                            else { continue }

                            // Capture detectedCategory from every event
                            if let cat = obj["detectedCategory"] as? String, !cat.isEmpty, cat != "unknown" {
                                latestCategory = cat
                            } else if let cat = obj["category"] as? String, !cat.isEmpty, cat != "unknown" {
                                latestCategory = cat
                            }

                            // Emit detected_item_name as soon as it arrives in any event —
                            // lets the CameraView header update before the full payload.
                            if let name = obj["detected_item_name"] as? String, !name.isEmpty {
                                continuation.yield(.detectedItem(name))
                            }

                            let type = obj["type"] as? String ?? ""

                            if type == "status" {
                                if let text = obj["text"] as? String {
                                    continuation.yield(.status(text))
                                }
                                continue
                            }

                            if type == "done" {
                                // Final event: payload lives under "result" key
                                guard let resultObj = obj["result"],
                                      let resultData = try? JSONSerialization.data(withJSONObject: resultObj)
                                else {
                                    // Fallback: try decoding the whole event as payload
                                    if let payload = try? decoder.decode(GeminiDiagnosisPayload.self, from: d) {
                                        var p = payload
                                        if p.detectedCategory == nil || p.detectedCategory!.isEmpty {
                                            p.detectedCategory = latestCategory
                                        }
                                        continuation.yield(.result(p))
                                    }
                                    break
                                }
                                do {
                                    var payload = try decoder.decode(GeminiDiagnosisPayload.self, from: resultData)
                                    if payload.detectedCategory == nil || payload.detectedCategory!.isEmpty {
                                        payload.detectedCategory = latestCategory
                                    }
                                    continuation.yield(.result(payload))
                                } catch {
                                    let preview = String(data: resultData, encoding: .utf8)?.prefix(600) ?? "<non-UTF8>"
                                    print("[Fixie] ❌ SSE done-event parse error — \(error)")
                                    print("[Fixie] ❌ result object (\(resultData.count) bytes): \(preview)")
                                    continuation.finish(throwing: BackendError.parseError(error.localizedDescription))
                                    return
                                }
                                break
                            }

                            // Unknown typed event or untyped chunk — try decoding as payload
                            let cleaned = stripFences(chunk)
                            if let cleanData = cleaned.data(using: .utf8),
                               var payload = try? decoder.decode(GeminiDiagnosisPayload.self, from: cleanData) {
                                if payload.detectedCategory == nil || payload.detectedCategory!.isEmpty {
                                    payload.detectedCategory = latestCategory
                                }
                                continuation.yield(.result(payload))
                                break
                            }
                        }
                    } else {
                        // ── Regular JSON mode ──────────────────────────────────
                        var raw = Data()
                        for try await byte in asyncBytes { raw.append(byte) }
                        let cleaned = stripFences(String(data: raw, encoding: .utf8) ?? "")
                        guard let cleanData = cleaned.data(using: .utf8) else {
                            continuation.finish(throwing: BackendError.parseError("Could not re-encode response")); return
                        }
                        do {
                            let payload = try decoder.decode(GeminiDiagnosisPayload.self, from: cleanData)
                            continuation.yield(.result(payload))
                        } catch {
                            let preview = String(data: cleanData, encoding: .utf8)?
                                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(600) ?? "<non-UTF8>"
                            print("[Fixie] ❌ Backend stream parse error — \(error)")
                            print("[Fixie] ❌ Raw response (\(cleanData.count) bytes): \(preview)")
                            continuation.finish(throwing: BackendError.parseError(error.localizedDescription))
                            return
                        }
                    }
                    continuation.finish()
                } catch let err as BackendError {
                    continuation.finish(throwing: err)
                } catch {
                    continuation.finish(throwing: BackendError.notDeployed)
                }
            }
        }
    }

    // MARK: – Video diagnosis

    /// Sends a video file to /api/diagnose-video as multipart/form-data.
    /// Returns the same GeminiDiagnosisPayload schema as the image endpoint.
    func diagnoseVideo(videoData: Data,
                       mimeType: String = "video/mp4",
                       category: RepairCategory? = nil,
                       userDescription: String = "") async throws -> GeminiDiagnosisPayload {
        let url = Config.backendBaseURL.appendingPathComponent("diagnose-video")
        let fields: [String: String] = [
            "category":        category?.rawValue ?? "",
            "user_description": userDescription
        ]
        return try await uploadMultipart(to: url, fileData: videoData,
                                         fileName: "video.mp4", mimeType: mimeType,
                                         fields: fields, timeout: 60)
    }

    // MARK: – Audio diagnosis

    /// Sends an audio file to /api/diagnose-audio as multipart/form-data.
    /// `audioData` should be a valid WAV or M4A file (not raw PCM).
    func diagnoseAudio(audioData: Data,
                       mimeType: String = "audio/wav",
                       category: RepairCategory? = nil) async throws -> GeminiDiagnosisPayload {
        let url = Config.backendBaseURL.appendingPathComponent("diagnose-audio")
        let fields: [String: String] = ["category": category?.rawValue ?? ""]
        return try await uploadMultipart(to: url, fileData: audioData,
                                         fileName: "audio.wav", mimeType: mimeType,
                                         fields: fields, timeout: 45)
    }

    // MARK: – Shared multipart upload

    private func uploadMultipart(to url: URL,
                                  fileData: Data,
                                  fileName: String,
                                  mimeType: String,
                                  fields: [String: String],
                                  timeout: TimeInterval) async throws -> GeminiDiagnosisPayload {
        let boundary = "fixie-boundary-\(UUID().uuidString)"
        let body     = buildMultipart(boundary: boundary, fileData: fileData,
                                       fileName: fileName, mimeType: mimeType, fields: fields)

        var req = URLRequest(url: url)
        req.httpMethod      = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody        = body
        req.timeoutInterval = timeout

        if let token = await fetchIDToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw BackendError.notDeployed
        }

        guard let http = response as? HTTPURLResponse else { throw BackendError.notDeployed }
        if http.statusCode == 404 || http.statusCode == 503 { throw BackendError.notDeployed }
        guard (200...299).contains(http.statusCode) else { throw BackendError.httpError(http.statusCode) }

        let cleaned = stripFences(String(data: data, encoding: .utf8) ?? "")
        guard let cleanData = cleaned.data(using: .utf8) else {
            throw BackendError.parseError("Could not re-encode response")
        }
        do {
            return try decoder.decode(GeminiDiagnosisPayload.self, from: cleanData)
        } catch {
            let preview = String(data: cleanData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(600) ?? "<non-UTF8>"
            print("[Fixie] ❌ Media backend parse error — decoder: \(error)")
            print("[Fixie] ❌ Raw response (\(cleanData.count) bytes): \(preview)")
            throw BackendError.parseError(error.localizedDescription)
        }
    }

    // MARK: – Multipart form-data builder

    private func buildMultipart(boundary: String, fileData: Data, fileName: String,
                                 mimeType: String, fields: [String: String]) -> Data {
        var body = Data()
        let nl   = "\r\n"
        func append(_ string: String) { body.append(Data(string.utf8)) }

        // File part
        append("--\(boundary)\(nl)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(nl)")
        append("Content-Type: \(mimeType)\(nl)\(nl)")
        body.append(fileData)
        append(nl)

        // Text fields
        for (name, value) in fields where !value.isEmpty {
            append("--\(boundary)\(nl)")
            append("Content-Disposition: form-data; name=\"\(name)\"\(nl)\(nl)")
            append(value + nl)
        }

        append("--\(boundary)--\(nl)")
        return body
    }

    // MARK: – String helpers

    /// Strips markdown code fences and trims whitespace from a JSON string.
    private func stripFences(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
         .replacingOccurrences(of: "```json", with: "")
         .replacingOccurrences(of: "```", with: "")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: – Keep-alive ping

    /// Fires a lightweight GET /api/ping to wake the Replit server before the user
    /// finishes framing their shot.  Call this when the camera view appears.
    /// Silently ignores all errors — it's best-effort only.
    func warmUp() {
        let url = Config.backendBaseURL.appendingPathComponent("ping")
        Task {
            _ = try? await session.data(from: url)
        }
    }

    // MARK: – Firebase Auth ID token (best-effort)

    private func fetchIDToken() async -> String? {
        return await FirebaseService.shared.currentUserIDToken()
    }
}

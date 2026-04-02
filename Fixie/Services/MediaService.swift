// Services/MediaService.swift
// Background upload service for repair photos and 5-second diagnostic videos.
//
// Storage path convention:
//   users/{userId}/projects/{projectId}/thumbnail.jpg   ← repair photo (JPEG)
//   users/{userId}/projects/{projectId}/clip.mp4        ← 5-second diagnostic video
//
// After upload the resulting HTTPS download URLs are written back into the
// Firestore project document so the web portal can access them.
//
// Requirements: FirebaseStorage, FirebaseFirestore linked via SPM (firebase-ios-sdk 12+).

import Foundation
import FirebaseStorage
import FirebaseFirestore

// MARK: – Upload result

struct MediaUploadResult: Sendable {
    let thumbnailURL: String?
    let videoURL:     String?
}

// MARK: – MediaService

@Observable @MainActor
final class MediaService {

    static let shared = MediaService()
    private init() {}

    /// True while any upload is in progress.
    var isUploading = false
    /// Captures the last upload error for display in the UI.
    var lastUploadError: String?

    // MARK: – Public API

    /// Upload photo and/or video for a repair project.
    /// Writes the resulting download URLs back into the Firestore project document.
    /// - Parameters:
    ///   - projectId:  The UUID string of the `RepairHistoryEntry` (used as the Firestore document ID).
    ///   - userId:     The signed-in user's UID.
    ///   - photoData:  JPEG-compressed repair photo, if available.
    ///   - videoData:  Raw MP4 data of the 5-second diagnostic clip, if available.
    /// - Returns:      URLs that were written to Firestore, or nil for each if upload was skipped.
    @discardableResult
    func uploadRepairMedia(
        projectId: String,
        userId:    String,
        photoData: Data?,
        videoData: Data?
    ) async -> MediaUploadResult {
        isUploading    = true
        lastUploadError = nil
        defer { isUploading = false }

        var thumbnailURL: String?
        var videoURL:     String?

        do {
            if let data = photoData {
                thumbnailURL = try await upload(
                    data:      data,
                    mimeType:  "image/jpeg",
                    storagePath: "users/\(userId)/projects/\(projectId)/thumbnail.jpg"
                )
            }

            if let data = videoData {
                videoURL = try await upload(
                    data:      data,
                    mimeType:  "video/mp4",
                    storagePath: "users/\(userId)/projects/\(projectId)/clip.mp4"
                )
            }

            // Patch the Firestore project document with the new URLs
            try await patchFirestoreURLs(
                projectId:    projectId,
                userId:       userId,
                thumbnailURL: thumbnailURL,
                videoURL:     videoURL
            )
        } catch {
            lastUploadError = error.localizedDescription
        }

        return MediaUploadResult(thumbnailURL: thumbnailURL, videoURL: videoURL)
    }

    // MARK: – Private helpers

    /// Uploads raw data to Firebase Storage and returns the HTTPS download URL.
    private func upload(data: Data, mimeType: String, storagePath: String) async throws -> String {
        let ref      = Storage.storage().reference(withPath: storagePath)
        let metadata = StorageMetadata()
        metadata.contentType = mimeType
        _ = try await ref.putDataAsync(data, metadata: metadata)
        return try await ref.downloadURL().absoluteString
    }

    /// Writes (merge) the download URLs into the matching Firestore project document.
    private func patchFirestoreURLs(
        projectId:    String,
        userId:       String,
        thumbnailURL: String?,
        videoURL:     String?
    ) async throws {
        var patch: [String: Any] = [:]
        if let url = thumbnailURL { patch["thumbnailURL"] = url }
        if let url = videoURL     { patch["videoURL"]     = url }
        guard !patch.isEmpty else { return }

        try await Firestore.firestore()
            .collection("users").document(userId)
            .collection("projects").document(projectId)
            .setData(patch, merge: true)
    }
}

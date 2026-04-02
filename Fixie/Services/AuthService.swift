// Services/AuthService.swift
// Apple Sign-In + Firebase Auth identity layer.
// Uses Firebase Auth UID (not Apple's cred.user) as the canonical user ID
// so Firestore rules (request.auth.uid == userId) are satisfied.
import AuthenticationServices
import CryptoKit
import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// MARK: – User model

struct FixieUser: Codable, Sendable {
    let id: String          // Firebase Auth UID — matches request.auth.uid in Firestore rules
    var displayName: String
    var email: String?
    var phoneNumber: String = ""
    var photoURL:    String = ""    // Firebase Storage download URL for profile avatar
    var address:     String = ""
    var city:        String = ""
    var state:       String = ""
    var zip:         String = ""

    var avatarInitials: String {
        let parts = displayName.split(separator: " ")
        switch parts.count {
        case 0:  return "?"
        case 1:  return String(parts[0].prefix(2)).uppercased()
        default: return (String(parts[0].prefix(1)) + String(parts[1].prefix(1))).uppercased()
        }
    }
}

// MARK: – AuthService

@Observable @MainActor
final class AuthService: NSObject {

    static let shared = AuthService()

    /// Posted when Firebase Auth confirms a signed-in user (Firestore reads are safe after this).
    static let authReadyNotification    = Notification.Name("com.fixie.authReady")
    /// Posted when the user signs out so ViewModels can wipe their local state.
    static let authSignedOutNotification = Notification.Name("com.fixie.authSignedOut")

    private var profileListener: ListenerRegistration?

    var currentUser: FixieUser?
    var isSigningIn = false
    var authError: String?

    private var currentNonce: String?
    private var signInContinuation: CheckedContinuation<FixieUser, Error>?
    private var pendingAppleCredential: ASAuthorizationAppleIDCredential?

    private override init() {
        super.init()

        // Restore from UserDefaults (fast path for returning users)
        if let data = UserDefaults.standard.data(forKey: "fixieUser"),
           let user = try? JSONDecoder().decode(FixieUser.self, from: data) {
            currentUser = user
        }

        // Keep in sync with Firebase Auth state — handles token refresh and
        // cross-device sign-outs. The listener fires once immediately on launch.
        Auth.auth().addStateDidChangeListener { [weak self] _, firebaseUser in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let firebaseUser {
                    // Always post auth-ready and (re-)start the profile listener regardless
                    // of whether we already have this user in memory. The early-return below
                    // only skips the currentUser assignment to prevent UI flicker; the
                    // Firestore listener and notification MUST fire on every cold launch so
                    // HomeViewModel can register its leads query listener and fetch the real name.
                    NotificationCenter.default.post(name: AuthService.authReadyNotification, object: nil)
                    self.startUserProfileListener(uid: firebaseUser.uid)

                    // Skip currentUser re-assignment if UID already matches — prevents
                    // redundant @Observable updates that cause nav-stack/sheet flicker.
                    if self.currentUser?.id == firebaseUser.uid { return }

                    let name = firebaseUser.displayName
                        ?? UserDefaults.standard.string(forKey: "fixieDisplayName")
                        ?? "Fixie User"
                    let user = FixieUser(id: firebaseUser.uid,
                                        displayName: name,
                                        email: firebaseUser.email)
                    self.currentUser = user
                    if let data = try? JSONEncoder().encode(user) {
                        UserDefaults.standard.set(data, forKey: "fixieUser")
                    }
                    // Ensure the Firestore profile exists for users who sign in silently
                    // on launch (e.g. returning users whose token was auto-refreshed).
                    // isNewUser = false → only merges identity fields, never touches role.
                    Task { await FirebaseService.shared.writeUserProfile(user, isNewUser: false) }
                } else {
                    guard self.currentUser != nil else { return }  // already signed out
                    self.currentUser = nil
                    UserDefaults.standard.removeObject(forKey: "fixieUser")
                    self.stopUserProfileListener()
                    NotificationCenter.default.post(name: AuthService.authSignedOutNotification, object: nil)
                }
            }
        }
    }

    var isSignedIn: Bool { currentUser != nil }

    // MARK: – Sign In with Apple

    func signInWithApple() async throws {
        isSigningIn = true
        authError   = nil
        defer { isSigningIn = false }

        let nonce    = randomNonce()
        currentNonce = nonce

        let provider = ASAuthorizationAppleIDProvider()
        let request  = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)

        // Wait for Apple's credential via delegate
        let appleUser = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<FixieUser, Error>) in
            self.signInContinuation = cont
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }

        // Sign into Firebase Auth — result.user.uid is the canonical Firebase UID
        guard let cred = pendingAppleCredential,
              let idTokenData = cred.identityToken,
              let idToken = String(data: idTokenData, encoding: .utf8)
        else { throw AuthError.missingIdentityToken }

        let firebaseCred = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce:    nonce,
            fullName:    cred.fullName
        )
        let result = try await Auth.auth().signIn(with: firebaseCred)
        pendingAppleCredential = nil

        // ── KEY FIX ──────────────────────────────────────────────────────────
        // Use result.user.uid (Firebase UID) — NOT cred.user (Apple UID).
        // Firestore rules check request.auth.uid == userId; only the Firebase
        // UID will match. Using the Apple UID causes "Permission denied".
        // ─────────────────────────────────────────────────────────────────────
        let canonicalUser = FixieUser(
            id:          result.user.uid,
            displayName: appleUser.displayName,
            email:       result.user.email ?? appleUser.email
        )

        currentUser = canonicalUser
        UserDefaults.standard.set(canonicalUser.displayName, forKey: "fixieDisplayName")
        if let data = try? JSONEncoder().encode(canonicalUser) {
            UserDefaults.standard.set(data, forKey: "fixieUser")
        }

        // Write profile to Firestore — isNewUser from Firebase Auth so role/createdAt
        // are only set on first signup; returning users only sync identity fields.
        let isNew = result.additionalUserInfo?.isNewUser ?? false
        Task { await FirebaseService.shared.writeUserProfile(canonicalUser, isNewUser: isNew) }
    }

    // MARK: – Sign Out

    func signOut() {
        stopUserProfileListener()
        try? Auth.auth().signOut()   // triggers addStateDidChangeListener → clears currentUser
    }

    // MARK: – Delete Account
    //
    // Required by App Store Guidelines (5.1.1) for apps that support account creation.
    // Deletes the Firestore user document, Firebase Auth account, and all local cache.
    // Subcollection cleanup (projects, failed_diagnostics, history) is handled by the
    // Firebase Cloud Function triggered on user deletion.

    func deleteAccount() async throws {
        guard let userId = currentUser?.id else { return }
        let db = Firestore.firestore()

        // 1. Delete Firestore user document
        try await db.collection("users").document(userId).delete()

        // 2. Delete Firebase Auth user — may throw requiresRecentLogin if credential is stale
        try await Auth.auth().currentUser?.delete()

        // 3. Clear all local state (auth state listener will nil out currentUser)
        UserDefaults.standard.removeObject(forKey: "fixieUser")
        UserDefaults.standard.removeObject(forKey: "pendingFCMToken")
        ActiveSession.clearLocal()
        ActiveServiceLead.clearPendingLead()
        ActiveServiceLead.saveAllLocal([])
    }

    // MARK: – Nonce helpers

    private func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: – User Profile Listener (Task 1: real-time name sync from Firestore)

    func startUserProfileListener(uid: String) {
        profileListener?.remove()
        let db = Firestore.firestore()
        profileListener = db.collection("users").document(uid)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error = error {
                    print("[Fixie] profileListener error: \(error.localizedDescription)")
                    return
                }
                guard let data = snapshot?.data() else { return }

                Task { @MainActor [weak self] in
                    guard let self, var user = self.currentUser else { return }
                    var changed = false
                    if let fullName = data["fullName"] as? String, !fullName.isEmpty,
                       fullName != "Fixie User", user.displayName != fullName {
                        user.displayName = fullName
                        UserDefaults.standard.set(fullName, forKey: "fixieDisplayName")
                        changed = true
                    }
                    if let phone = data["phoneNumber"] as? String, user.phoneNumber != phone {
                        user.phoneNumber = phone
                        changed = true
                    }
                    if let photo = data["photoURL"] as? String, user.photoURL != photo {
                        user.photoURL = photo
                        changed = true
                    }
                    if let addr = data["address"] as? String, user.address != addr {
                        user.address = addr
                        changed = true
                    }
                    if let c = data["city"] as? String, user.city != c {
                        user.city = c
                        changed = true
                    }
                    if let s = data["state"] as? String, user.state != s {
                        user.state = s
                        changed = true
                    }
                    if let z = data["zip"] as? String, user.zip != z {
                        user.zip = z
                        changed = true
                    }
                    guard changed else { return }
                    self.currentUser = user
                    if let encoded = try? JSONEncoder().encode(user) {
                        UserDefaults.standard.set(encoded, forKey: "fixieUser")
                    }
                }
            }
    }

    func stopUserProfileListener() {
        profileListener?.remove()
        profileListener = nil
    }

    // MARK: – Errors

    enum AuthError: LocalizedError {
        case missingIdentityToken
        var errorDescription: String? { "Apple identity token was missing." }
    }
}

// MARK: – ASAuthorizationControllerDelegate

extension AuthService: ASAuthorizationControllerDelegate {

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else { return }

        // Apple only sends fullName on first login — persist it for future launches
        let fullName = [cred.fullName?.givenName, cred.fullName?.familyName]
            .compactMap { $0 }.joined(separator: " ")

        let storedName: String
        if !fullName.isEmpty {
            storedName = fullName
            UserDefaults.standard.set(fullName, forKey: "appleDisplayName_\(cred.user)")
        } else {
            storedName = UserDefaults.standard.string(forKey: "appleDisplayName_\(cred.user)") ?? "Fixie User"
        }

        // The id here is temporary (Apple UID) — replaced with Firebase UID after signIn()
        let appleUser = FixieUser(id: cred.user, displayName: storedName, email: cred.email)

        Task { @MainActor in
            self.pendingAppleCredential = cred
            self.signInContinuation?.resume(returning: appleUser)
            self.signInContinuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            self.signInContinuation?.resume(throwing: error)
            self.signInContinuation = nil
            self.authError = error.localizedDescription
        }
    }
}

// MARK: – Presentation context

extension AuthService: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

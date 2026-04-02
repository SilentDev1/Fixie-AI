// Views/Profile/ProfileSheetView.swift
// Liquid Glass identity sheet — shows sign-in prompt or signed-in user profile.
import SwiftUI
import PhotosUI

struct ProfileSheetView: View {
    @State private var auth  = AuthService.shared
    @State private var store = RepairHistoryStore.shared
    @Environment(\.dismiss) private var dismiss

    // Edit-profile state
    @State private var showEditSheet       = false
    @State private var avatarPickerItem:   PhotosPickerItem? = nil
    @State private var localAvatarImage:   UIImage? = nil   // preview before upload

    // Delete account state
    @State private var showDeleteConfirm   = false
    @State private var isDeletingAccount   = false
    @State private var deleteError:        String? = nil

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 36, height: 5)
                    .padding(.top, Theme.spacingM)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: Theme.spacingL) {
                        if auth.isSignedIn, let user = auth.currentUser {
                            signedInContent(user: user)
                        } else {
                            signedOutContent
                        }
                        Spacer(minLength: Theme.spacingXL)
                    }
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.top, Theme.spacingL)
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
        .sheet(isPresented: $showEditSheet) {
            if let user = auth.currentUser {
                EditProfileSheet(user: user)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        // Avatar photo picker
        .photosPicker(isPresented: .constant(false), selection: $avatarPickerItem, matching: .images)
        .onChange(of: avatarPickerItem) { _, item in
            guard let item else { return }
            avatarPickerItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img  = UIImage(data: data) {
                    localAvatarImage = img
                    let jpeg = img.jpegData(compressionQuality: 0.8)
                    try? await FirebaseService.shared.updateUserProfile(
                        name:       auth.currentUser?.displayName ?? "",
                        phone:      auth.currentUser?.phoneNumber ?? "",
                        avatarData: jpeg
                    )
                }
            }
        }
    }

    // MARK: – Signed-in view

    private func signedInContent(user: FixieUser) -> some View {
        VStack(spacing: Theme.spacingL) {

            // Avatar + edit-photo overlay
            ZStack(alignment: .bottomTrailing) {
                avatarCircle(user: user)

                PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: 0x1A1A2E))
                            .frame(width: 28, height: 28)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.brandPrimary)
                    }
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: 4)
            }

            // Name + email + edit button
            VStack(spacing: Theme.spacingXS) {
                HStack(spacing: Theme.spacingS) {
                    Text(user.displayName)
                        .font(Theme.titleMedium)
                        .foregroundStyle(Theme.textPrimary)
                    Button { showEditSheet = true } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.brandPrimary.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }

                if let email = user.email {
                    if email.hasSuffix("@privaterelay.appleid.com") {
                        Label("Verified Apple Account", systemImage: "apple.logo")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text(email)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            // Contact info card
            contactCard(user: user)

            statsRow

            // Support & legal links
            VStack(spacing: 0) {
                Link(destination: URL(string: "https://fixieai.app/support")!) {
                    HStack(spacing: Theme.spacingM) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.brandPrimary)
                            .frame(width: 20)
                        Text("Support")
                            .font(Theme.bodyRegular)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.vertical, Theme.spacingS)
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1))

            if let err = deleteError {
                Text(err)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.dangerRed)
                    .multilineTextAlignment(.center)
            }

            // Sign out
            Button {
                auth.signOut()
                dismiss()
            } label: {
                Text("Sign Out")
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.dangerRed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacingM)
                    .background(Theme.dangerRed.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.radiusS))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
                        .strokeBorder(Theme.dangerRed.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)

            // Delete account (required by App Store Guidelines 5.1.1)
            Button { showDeleteConfirm = true } label: {
                Group {
                    if isDeletingAccount {
                        ProgressView().tint(Theme.dangerRed)
                    } else {
                        Text("Delete Account")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.dangerRed.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.spacingS)
            }
            .buttonStyle(.plain)
            .disabled(isDeletingAccount)
            .confirmationDialog(
                "Delete Account",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete My Account", role: .destructive) {
                    Task {
                        isDeletingAccount = true
                        deleteError = nil
                        do {
                            try await auth.deleteAccount()
                            dismiss()
                        } catch {
                            deleteError = "Could not delete account. Please sign out and sign back in, then try again."
                        }
                        isDeletingAccount = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete your account and all associated data. This cannot be undone.")
            }
        }
    }

    // MARK: – Avatar

    @ViewBuilder
    private func avatarCircle(user: FixieUser) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Theme.brandPrimary, Color(hex: 0x29B6F6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 88, height: 88)

            if let local = localAvatarImage {
                Image(uiImage: local)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 88, height: 88)
                    .clipShape(Circle())
            } else if !user.photoURL.isEmpty, let url = URL(string: user.photoURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(Circle())
                    default:
                        Text(user.avatarInitials)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                    }
                }
            } else {
                Text(user.avatarInitials)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
            }
        }
    }

    // MARK: – Contact card

    private func contactCard(user: FixieUser) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Contact Info", systemImage: "person.text.rectangle")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button { showEditSheet = true } label: {
                    Text("Edit")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.brandPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.spacingM)
            .padding(.top, Theme.spacingM)
            .padding(.bottom, Theme.spacingS)

            Divider().background(.white.opacity(0.1))

            contactRow(icon: "phone.fill",
                       label: user.phoneNumber.isEmpty ? "Add phone number" : user.phoneNumber,
                       isEmpty: user.phoneNumber.isEmpty)

            Divider().background(.white.opacity(0.08))

            Divider().background(.white.opacity(0.08))

            contactRow(icon: "envelope.fill",
                       label: user.email?.hasSuffix("@privaterelay.appleid.com") == true
                                ? "Apple private relay" : (user.email ?? "No email"),
                       isEmpty: user.email == nil)

            Divider().background(.white.opacity(0.08))

            let addressLine: String = {
                let parts = [user.address, user.city, user.state, user.zip].filter { !$0.isEmpty }
                return parts.isEmpty ? "Add address" : parts.joined(separator: ", ")
            }()
            contactRow(icon: "location.fill",
                       label: addressLine,
                       isEmpty: user.address.isEmpty && user.city.isEmpty)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
            .strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    private func contactRow(icon: String, label: String, isEmpty: Bool) -> some View {
        HStack(spacing: Theme.spacingM) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(isEmpty ? Theme.textTertiary : Theme.brandPrimary)
                .frame(width: 20)
            Text(label)
                .font(Theme.bodyRegular)
                .foregroundStyle(isEmpty ? Theme.textTertiary : Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, Theme.spacingM)
        .padding(.vertical, Theme.spacingS)
    }

    // MARK: – Stats

    private var statsRow: some View {
        let completed  = store.entries.filter(\.isCompleted).count
        let categories = Set(store.entries.map(\.categoryRaw)).count

        return HStack(spacing: 0) {
            statCell(value: "\(store.entries.count)", label: "Repairs")
            Divider().frame(height: 36).background(.white.opacity(0.15))
            statCell(value: "\(completed)", label: "Completed")
            Divider().frame(height: 36).background(.white.opacity(0.15))
            statCell(value: "\(categories)", label: "Categories")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
            .strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: – Signed-out view

    private var signedOutContent: some View {
        VStack(spacing: Theme.spacingL) {
            Spacer(minLength: Theme.spacingL)

            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 108, height: 108)
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 50))
                    .foregroundStyle(Theme.textTertiary)
            }

            VStack(spacing: Theme.spacingS) {
                Text("Sign in to Fixie AI")
                    .font(Theme.titleMedium)
                    .foregroundStyle(Theme.textPrimary)
                Text("Save your repair history across devices\nand unlock all features.")
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            AppleSignInButton()
                .frame(height: 52)

            if let err = auth.authError {
                Text(err)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.dangerRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingM)
            }

            Text(Config.aiDisclosureText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacingL)
        }
    }
}

// MARK: – Edit Profile Sheet

struct EditProfileSheet: View {
    let user: FixieUser
    @Environment(\.dismiss) private var dismiss

    @State private var name:      String = ""
    @State private var phone:     String = ""
    @State private var address:   String = ""
    @State private var city:      String = ""
    @State private var state:     String = ""
    @State private var zip:       String = ""
    @State private var isSaving   = false
    @State private var saveError: String? = nil

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()

            VStack(spacing: 0) {
                // Handle
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 36, height: 5)
                    .padding(.top, Theme.spacingM)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Theme.spacingL) {
                        HStack {
                            Text("Edit Profile")
                                .font(Theme.titleMedium)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Button("Cancel") { dismiss() }
                                .font(Theme.bodyRegular)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        profileField(label: "Full Name",     icon: "person.fill",
                                     placeholder: "Your name", text: $name)
                            .autocorrectionDisabled()

                        profileField(label: "Phone Number",  icon: "phone.fill",
                                     placeholder: "(555) 555-5555", text: $phone,
                                     keyboard: .phonePad)

                        profileField(label: "Street Address", icon: "location.fill",
                                     placeholder: "Street address", text: $address)

                        HStack(spacing: Theme.spacingM) {
                            profileField(label: "City",  icon: "building.2",
                                         placeholder: "City", text: $city)
                            profileField(label: "State", icon: "map",
                                         placeholder: "NH",   text: $state)
                                .frame(maxWidth: 80)
                            profileField(label: "ZIP",   icon: "number",
                                         placeholder: "ZIP", text: $zip,
                                         keyboard: .numberPad)
                                .frame(maxWidth: 100)
                        }

                        Text("Your contact info and address are shared with the pro when you request service.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)

                        if let err = saveError {
                            Text(err)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.dangerRed)
                        }

                        // Save button
                        Button {
                            Task {
                                isSaving = true
                                saveError = nil
                                do {
                                    try await FirebaseService.shared.updateUserProfile(
                                        name:    name,
                                        phone:   phone,
                                        address: address,
                                        city:    city,
                                        state:   state,
                                        zip:     zip
                                    )
                                    dismiss()
                                } catch {
                                    saveError = error.localizedDescription
                                }
                                isSaving = false
                            }
                        } label: {
                            HStack {
                                if isSaving { ProgressView().tint(.black) }
                                Text(isSaving ? "Saving…" : "Save Changes")
                                    .font(Theme.bodyBold)
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.spacingM)
                            .background(
                                Capsule().fill(LinearGradient(
                                    colors: [Theme.brandPrimary, Color(hex: 0x29B6F6)],
                                    startPoint: .leading, endPoint: .trailing
                                ))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                    }
                    .padding(Theme.spacingM)
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
        .onAppear {
            name    = user.displayName == "Fixie User" ? "" : user.displayName
            phone   = user.phoneNumber
            address = user.address
            city    = user.city
            state   = user.state
            zip     = user.zip
        }
    }

    @ViewBuilder
    private func profileField(
        label:       String,
        icon:        String,
        placeholder: String,
        text:        Binding<String>,
        keyboard:    UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 20)
                TextField(placeholder, text: text)
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textPrimary)
                    .keyboardType(keyboard)
            }
            .padding(Theme.spacingM)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
                .strokeBorder(Theme.brandPrimary.opacity(0.25), lineWidth: 1))
        }
    }
}

// MARK: – Apple Sign-In button

private struct AppleSignInButton: View {
    @State private var auth = AuthService.shared

    var body: some View {
        Button {
            Task { try? await auth.signInWithApple() }
        } label: {
            HStack(spacing: Theme.spacingS) {
                if auth.isSigningIn {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Sign in with Apple")
                        .font(Theme.bodyBold)
                }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.spacingM)
            .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.radiusS))
        }
        .buttonStyle(.plain)
        .disabled(auth.isSigningIn)
    }
}

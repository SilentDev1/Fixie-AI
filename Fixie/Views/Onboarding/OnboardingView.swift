// Views/Onboarding/OnboardingView.swift
import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var page = 0

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()
            TabView(selection: $page) {
                WelcomePage().tag(0)
                PermissionsPage().tag(1)
                ReadyPage(hasSeenOnboarding: $hasSeenOnboarding).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: – Page 1: Welcome

private struct WelcomePage: View {
    @State private var scale:   CGFloat = 0.6
    @State private var opacity: Double  = 0

    var body: some View {
        VStack(spacing: Theme.spacingXL) {
            Spacer()

            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 80))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.brandPrimary, Color(hex: 0x29B6F6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .scaleEffect(scale)
                .opacity(opacity)
                .onAppear {
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.6).delay(0.1)) {
                        scale   = 1.0
                        opacity = 1.0
                    }
                }

            VStack(spacing: Theme.spacingM) {
                Text("Fixie AI")
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.textPrimary)
                Text("Your AI-powered repair companion.\nPoint. Diagnose. Fix.")
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(opacity)

            Spacer()
            Spacer()
        }
        .padding(Theme.spacingXL)
    }
}

// MARK: – Page 2: Permissions

private struct PermissionsPage: View {
    @State private var cameraGranted = false
    @State private var micGranted    = false

    var body: some View {
        VStack(spacing: Theme.spacingXL) {
            Spacer()

            VStack(spacing: Theme.spacingM) {
                Text("Permissions")
                    .font(Theme.titleMedium)
                    .foregroundStyle(Theme.textPrimary)
                Text("Fixie needs camera and microphone access to diagnose and guide repairs.")
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: Theme.spacingM) {
                PermissionButton(
                    icon: "camera.fill",
                    title: "Camera",
                    description: "Scan and diagnose appliances",
                    isGranted: cameraGranted
                ) {
                    AVCaptureDevice.requestAccess(for: .video) { granted in
                        Task { @MainActor in cameraGranted = granted }
                    }
                }

                PermissionButton(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Listen mode for sound diagnosis",
                    isGranted: micGranted
                ) {
                    AVAudioApplication.requestRecordPermission { granted in
                        Task { @MainActor in micGranted = granted }
                    }
                }
            }

            Spacer()
            Spacer()
        }
        .padding(Theme.spacingXL)
    }
}

private struct PermissionButton: View {
    let icon:        String
    let title:       String
    let description: String
    let isGranted:   Bool
    let action:      () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.spacingM) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(isGranted ? Theme.brandSecondary : Theme.brandPrimary)
                    .frame(width: 44, height: 44)
                    .background(
                        (isGranted ? Theme.brandSecondary : Theme.brandPrimary).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.bodyBold)
                        .foregroundStyle(Theme.textPrimary)
                    Text(description)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Image(systemName: isGranted ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(isGranted ? Theme.brandSecondary : Theme.textTertiary)
            }
            .padding(Theme.spacingM)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusM))
        }
        .buttonStyle(.plain)
        .disabled(isGranted)
    }
}

// MARK: – Page 3: Ready

private struct ReadyPage: View {
    @Binding var hasSeenOnboarding: Bool

    var body: some View {
        VStack(spacing: Theme.spacingXL) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(Theme.brandSecondary)

            VStack(spacing: Theme.spacingM) {
                Text("You're all set!")
                    .font(Theme.titleMedium)
                    .foregroundStyle(Theme.textPrimary)
                Text("Start by pointing your camera at any appliance and let Fixie do the rest.")
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                hasSeenOnboarding = true
            } label: {
                Text("Start Diagnosing")
                    .font(Theme.bodyBold)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacingM)
                    .background(
                        LinearGradient(
                            colors: [Theme.brandPrimary, Color(hex: 0x29B6F6)],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(Theme.spacingXL)
    }
}

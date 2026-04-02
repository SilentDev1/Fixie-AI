// Views/Camera/CameraView.swift
import SwiftUI
import AVFoundation

struct CameraView: View {
    var category: RepairCategory? = nil
    var startInListenMode: Bool   = false
    var userDescription: String   = ""   // optional text the user typed before opening the camera
    var onRepairExited: (() -> Void)? = nil   // closes the sheet from HomeView when repair pauses/exits

    @State private var viewModel     = CameraViewModel()
    @State private var navigateToHub = false
    @State private var completedGuide: RepairGuide? = nil
    @State private var hasStarted    = false
    @Namespace private var cameraNamespace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                // ── Live preview ─────────────────────────────────────────
                CameraPreviewView(session: viewModel.captureSession)
                    .ignoresSafeArea()

                // ── Scan overlay ─────────────────────────────────────────
                scanOverlay

                // ── Top bar ──────────────────────────────────────────────
                topBar

                // ── Bottom controls ──────────────────────────────────────
                VStack {
                    Spacer()
                    bottomControls
                }
            }
            .onAppear {
                guard !hasStarted else { return }
                hasStarted = true
                viewModel.category        = category
                viewModel.userDescription = userDescription   // thread description into diagnosis
                viewModel.requestAndStart()
                if startInListenMode && !viewModel.isListenMode {
                    viewModel.toggleListenMode()
                }
            }
            .onDisappear { viewModel.stop() }
            .onChange(of: viewModel.phase) { _, newPhase in
                if case .done(let guide) = newPhase {
                    completedGuide = guide
                    navigateToHub = true
                }
            }
            // Phase 5: go directly to Repair Hub (bypasses DiagnosisResultView)
            .navigationDestination(isPresented: $navigateToHub) {
                if let guide = completedGuide {
                    RepairHubView(
                        guide: guide,
                        capturedImage: viewModel.capturedImage,
                        transitionNamespace: cameraNamespace,
                        onRepairExited: onRepairExited
                    )
                }
            }
            .navigationBarHidden(true)
        }
    }

    // MARK: – Scan overlay

    private var scanOverlay: some View {
        ZStack {
            // Darkened vignette
            RadialGradient(
                colors: [.clear, .black.opacity(0.55)],
                center: .center,
                startRadius: 120,
                endRadius: 380
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Corner brackets
            ViewfinderBrackets()
                .stroke(Theme.brandPrimary, lineWidth: 2.5)
                .frame(width: 240, height: 240)

            // Scanning pulse ring (visible during idle / scanning)
            if case .scanning = viewModel.phase {
                PulseRing(color: Theme.brandPrimary)
            }

            // Analyzing overlay
            if case .analyzing(let msg) = viewModel.phase {
                analyzingOverlay(message: msg)
            }

            // Error overlay
            if case .error(let msg) = viewModel.phase {
                errorOverlay(message: msg)
            }

            // Hint text at bottom of viewfinder
            VStack {
                Spacer()
                Spacer()
                Text(viewModel.hintText)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.vertical, Theme.spacingXS)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 140)
            }
        }
    }

    // MARK: – Top bar

    private var topBar: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Spacer()

                // Show Vision-detected item name once available, else category chip.
                if !viewModel.detectedItemName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.brandPrimary)
                        Text(viewModel.detectedItemName)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.vertical, Theme.spacingXS)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.brandPrimary.opacity(0.4), lineWidth: 1))
                } else if let cat = viewModel.category {
                    Label(cat.rawValue, systemImage: cat.icon)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, Theme.spacingM)
                        .padding(.vertical, Theme.spacingXS)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Spacer()

                // Listen mode toggle
                Button { viewModel.toggleListenMode() } label: {
                    Image(systemName: viewModel.isListenMode ? "mic.fill" : "mic")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(viewModel.isListenMode ? Theme.brandPrimary : Theme.textPrimary)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle().strokeBorder(
                                viewModel.isListenMode ? Theme.brandPrimary : Color.clear,
                                lineWidth: 1.5
                            )
                        )
                }
            }
            .padding(.horizontal, Theme.spacingM)
            .padding(.top, Theme.spacingL)
            Spacer()
        }
    }

    // MARK: – Bottom controls

    private var bottomControls: some View {
        ZStack {
            // Frosted bar
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: 120)
                .ignoresSafeArea(edges: .bottom)

            HStack(spacing: Theme.spacingXL) {
                // Thumbnail of last captured image
                Group {
                    if let img = viewModel.capturedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.spacingS))
                    } else {
                        RoundedRectangle(cornerRadius: Theme.spacingS)
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 48, height: 48)
                    }
                }

                // Capture / Submit button
                captureOrSubmitButton

                // Flash / tip button
                Button {} label: {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 48, height: 48)
                }
            }
            .padding(.bottom, Theme.spacingL)
        }
    }

    @ViewBuilder
    private var captureOrSubmitButton: some View {
        if viewModel.isListenMode {
            // Submit audio for analysis
            Button { viewModel.submitAudioDiagnosis() } label: {
                ZStack {
                    Circle()
                        .fill(Theme.brandPrimary)
                        .frame(width: 72, height: 72)
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .buttonStyle(.plain)
        } else {
            // Standard shutter
            Button {
                let isAnalyzing: Bool
                if case .analyzing = viewModel.phase { isAnalyzing = true } else { isAnalyzing = false }
                guard !isAnalyzing else { return }
                viewModel.capturePhoto()
            } label: {
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: 72, height: 72)
                    .overlay(
                        Circle()
                            .fill(.white)
                            .padding(6)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: – Analyzing HUD (Liquid Glass + AR shimmer)

    @ViewBuilder
    private func analyzingOverlay(message: String) -> some View {
        ZStack {
            // AR particle shimmer overlaid on the live feed
            ARScanShimmer()

            // Expert persona pill — centered on screen, below the viewfinder brackets
            ExpertPersonaHUD(message: message)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.9).combined(with: .opacity),
                    removal:   .opacity
                ))
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: message)
    }

    private func errorOverlay(message: String) -> some View {
        VStack(spacing: Theme.spacingM) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.dangerRed)
            Text(message)
                .font(Theme.bodyRegular)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                viewModel.phase = .scanning
                viewModel.hintText = "Point camera at the appliance or equipment"
            }
            .font(Theme.bodyBold)
            .foregroundStyle(Theme.brandPrimary)
        }
        .padding(Theme.spacingXL)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusM))
        .padding(.horizontal, Theme.spacingL)
    }
}

// MARK: – Viewfinder bracket shape

private struct ViewfinderBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let arm: CGFloat = rect.width * 0.20
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            // top-left
            (CGPoint(x: rect.minX, y: rect.minY + arm),
             CGPoint(x: rect.minX, y: rect.minY),
             CGPoint(x: rect.minX + arm, y: rect.minY)),
            // top-right
            (CGPoint(x: rect.maxX - arm, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.minY + arm)),
            // bottom-right
            (CGPoint(x: rect.maxX, y: rect.maxY - arm),
             CGPoint(x: rect.maxX, y: rect.maxY),
             CGPoint(x: rect.maxX - arm, y: rect.maxY)),
            // bottom-left
            (CGPoint(x: rect.minX + arm, y: rect.maxY),
             CGPoint(x: rect.minX, y: rect.maxY),
             CGPoint(x: rect.minX, y: rect.maxY - arm)),
        ]
        for (p1, corner, p2) in corners {
            path.move(to: p1)
            path.addLine(to: corner)
            path.addLine(to: p2)
        }
        return path
    }
}

// MARK: – Pulse ring animation

private struct PulseRing: View {
    let color: Color
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.6

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 1.5)
            .frame(width: 260, height: 260)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    scale   = 1.18
                    opacity = 0
                }
            }
    }
}

// MARK: – Expert Persona HUD pill
// message is driven by DiagnosisEngine.localStatuses cycling every 3s — no internal timer needed.

private struct ExpertPersonaHUD: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            // Three staggered pulsing dots
            HStack(spacing: 4) {
                ForEach(Array(0..<3), id: \.self) { i in
                    PulseDot(delay: Double(i) * 0.18)
                }
            }

            Text(message)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .id(message)   // forces SwiftUI to re-render with transition on text change
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: Theme.brandPrimary.opacity(0.28), radius: 14, y: 5)
    }
}

private struct PulseDot: View {
    let delay: Double
    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 0.4

    var body: some View {
        Circle()
            .fill(Theme.brandPrimary)
            .frame(width: 6, height: 6)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)
                    .delay(delay)
                ) {
                    scale = 1.0
                    opacity = 1.0
                }
            }
    }
}

// MARK: – AR scan shimmer particles

private struct ARScanShimmer: View {
    // 24 particles scattered in the ~240×240 viewfinder zone
    private let particles: [ShimmerParticle] = (0..<24).map { _ in ShimmerParticle() }

    var body: some View {
        GeometryReader { geo in
            let cx = geo.size.width  / 2
            let cy = geo.size.height / 2
            let half: CGFloat = 120   // half of 240-pt bracket frame

            ZStack {
                ForEach(particles) { p in
                    ShimmerDot(particle: p, cx: cx, cy: cy, half: half)
                }

                // Animated horizontal scan line sweeping through the viewfinder
                ScanLine(cx: cx, cy: cy, half: half)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ShimmerParticle: Identifiable {
    let id = UUID()
    // Normalized position within ±1 of centre (mapped to ±half pt)
    let nx: CGFloat = CGFloat.random(in: -0.95...0.95)
    let ny: CGFloat = CGFloat.random(in: -0.95...0.95)
    let size: CGFloat = CGFloat.random(in: 2...5)
    let duration: Double = Double.random(in: 1.2...2.8)
    let delay: Double = Double.random(in: 0...2.5)
}

private struct ShimmerDot: View {
    let particle: ShimmerParticle
    let cx: CGFloat
    let cy: CGFloat
    let half: CGFloat

    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.6

    var body: some View {
        Circle()
            .fill(Theme.brandPrimary.opacity(0.85))
            .frame(width: particle.size, height: particle.size)
            .scaleEffect(scale)
            .opacity(opacity)
            .position(
                x: cx + particle.nx * half,
                y: cy + particle.ny * half
            )
            .onAppear {
                withAnimation(
                    .easeInOut(duration: particle.duration)
                    .repeatForever(autoreverses: true)
                    .delay(particle.delay)
                ) {
                    opacity = Double.random(in: 0.5...1.0)
                    scale   = 1.0
                }
            }
    }
}

private struct ScanLine: View {
    let cx: CGFloat
    let cy: CGFloat
    let half: CGFloat

    @State private var offsetY: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, Theme.brandPrimary.opacity(0.55), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: half * 2, height: 1.5)
            .position(x: cx, y: cy + offsetY)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 2.2)
                    .repeatForever(autoreverses: true)
                ) {
                    offsetY = half * 0.9
                }
                // Start mid-cycle so it doesn't always begin at top
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) {
                    offsetY = -half * 0.9
                }
            }
    }
}

#Preview {
    CameraView(category: .majorAppliances)
}

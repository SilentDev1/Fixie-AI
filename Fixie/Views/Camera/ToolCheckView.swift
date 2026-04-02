// Views/Camera/ToolCheckView.swift
import SwiftUI

struct ToolCheckView: View {
    let requiredTools: [String]
    var transitionNamespace: Namespace.ID
    /// Called when the user closes the scan view after a scan completes.
    /// `found` = tool names detected, `missing` = required tools not seen.
    var onComplete: ((_ found: [String], _ missing: [String]) -> Void)? = nil

    @State private var viewModel: ToolCheckViewModel
    @Environment(\.dismiss) private var dismiss

    init(requiredTools: [String], transitionNamespace: Namespace.ID,
         onComplete: ((_ found: [String], _ missing: [String]) -> Void)? = nil) {
        self.requiredTools = requiredTools
        self.transitionNamespace = transitionNamespace
        self.onComplete = onComplete
        self._viewModel = State(wrappedValue: ToolCheckViewModel(requiredTools: requiredTools))
    }

    var body: some View {
        ZStack {
            // ── Background: frozen photo (after capture) or live viewfinder (before) ──
            if let captured = viewModel.capturedImage {
                // Dark background for letterbox bars when image doesn't fill screen
                Color.black.ignoresSafeArea()
                // scaledToFit: full image visible, no cropping, no zoom.
                // ignoresSafeArea keeps the image coordinate space identical to the
                // GeometryReader below — both must measure the same full-screen rect
                // so bounding boxes map correctly onto the frozen photo.
                Image(uiImage: captured)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .matchedGeometryEffect(id: "arPane", in: transitionNamespace)
            } else {
                CameraPreviewView(session: viewModel.camera.session)
                    .ignoresSafeArea()
                    .matchedGeometryEffect(id: "arPane", in: transitionNamespace)
            }

            // ── Bounding box overlays mapped to the actual image rect ──
            if let captured = viewModel.capturedImage {
                GeometryReader { geo in
                    let imgRect = imageDisplayRect(imageSize: captured.size, containerSize: geo.size)
                    ForEach(viewModel.tools.filter { $0.boundingBox != nil }) { tool in
                        if let box = tool.boundingBox {
                            toolOverlay(tool: tool, box: box, in: imgRect)
                        }
                    }
                }
                .ignoresSafeArea()
            }

            // ── Scanning status bar ────────────────────────────────────
            VStack {
                scanStatusBar
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.top, Theme.spacingL)
                Spacer()
            }

            // ── Checklist sidebar + CTA ────────────────────────────────
            VStack {
                Spacer()
                bottomPanel
            }
        }
        .onAppear { viewModel.requestAndStart() }
        .onDisappear { viewModel.stop() }
    }

    // MARK: – Status bar

    private var scanStatusBar: some View {
        HStack(spacing: Theme.spacingM) {
            switch viewModel.phase {
            case .streaming:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.brandPrimary))
                    .scaleEffect(0.8)
                Text("Scanning Tools…")
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.textPrimary)
            case .done:
                Image(systemName: viewModel.allRequiredFound ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(viewModel.allRequiredFound ? Theme.brandSecondary : Theme.warningAmber)
                Text(viewModel.hintText)
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            default:
                Image(systemName: "camera.viewfinder")
                    .foregroundStyle(Theme.brandPrimary)
                Text(viewModel.hintText)
                    .font(Theme.bodyBold)
                    .lineLimit(2)
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            Button {
                if viewModel.phase == .done { fireComplete() }
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusM))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusM)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: – Bounding box coordinate helpers

    /// Returns the rect that a scaledToFit image occupies inside its container.
    /// Bounding box normalized coords (0–1) map to this rect, not the full container.
    private func imageDisplayRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width,
                        containerSize.height / imageSize.height)
        let w = imageSize.width  * scale
        let h = imageSize.height * scale
        return CGRect(
            x: (containerSize.width  - w) / 2,
            y: (containerSize.height - h) / 2,
            width: w, height: h
        )
    }

    // MARK: – Real-time tool overlay (bounding box → screen coords)

    private func toolOverlay(tool: IdentifiedTool, box: PartBoundingBox, in imgRect: CGRect) -> some View {
        let x = imgRect.origin.x + box.x * imgRect.width
        let y = imgRect.origin.y + box.y * imgRect.height
        let w = box.width  * imgRect.width
        let h = box.height * imgRect.height

        return ZStack(alignment: .topLeading) {
            // Box outline
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    tool.isRequired && tool.isFound ? Theme.brandSecondary :
                    tool.isRequired               ? Theme.dangerRed :
                    Color.white.opacity(0.4),
                    lineWidth: 1.5
                )
                .frame(width: w, height: h)

            // Label chip
            HStack(spacing: 4) {
                Image(systemName: tool.isFound ? "checkmark.seal.fill" : "xmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(tool.name)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(tool.isFound ? .black : Theme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                tool.isFound ? Theme.brandSecondary : Theme.dangerRed,
                in: Capsule()
            )
            .offset(y: -16)
        }
        .position(x: x + w / 2, y: y + h / 2)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: tool.isFound)
    }

    // MARK: – Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            // Checklist
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacingS) {
                    ForEach(viewModel.tools.filter(\.isRequired)) { tool in
                        toolChip(tool)
                    }
                }
                .padding(.horizontal, Theme.spacingM)
                .padding(.vertical, Theme.spacingS)
            }

            Divider().background(Color.white.opacity(0.08))

            // Action row
            HStack(spacing: Theme.spacingM) {
                // Scan / Rescan
                Button {
                    if viewModel.phase == .done {
                        viewModel.reset()
                    } else {
                        viewModel.scanTools()
                    }
                } label: {
                    let label: String = {
                        switch viewModel.phase {
                        case .done:      return "Retake"
                        case .streaming: return "Analyzing…"
                        default:         return "📷 Take Photo"
                        }
                    }()
                    Text(label)
                        .font(Theme.bodyBold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.spacingM)
                        .background(Theme.brandPrimary, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.phase == .streaming || viewModel.phase == .requestingPermission)

                // Done (only enabled when all found or user overrides)
                Button { fireComplete(); dismiss() } label: {
                    Text(viewModel.allRequiredFound ? "Done ✓" : "Proceed Anyway")
                        .font(Theme.bodyBold)
                        .foregroundStyle(viewModel.allRequiredFound ? .black : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.spacingM)
                        .background(
                            viewModel.allRequiredFound
                                ? Theme.brandSecondary
                                : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: Theme.radiusM)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.spacingM)
        }
        .background(.ultraThinMaterial)
        .ignoresSafeArea(edges: .bottom)
    }

    private func fireComplete() {
        let found   = viewModel.foundRequired.map(\.name)
        let missing = viewModel.missingTools.map(\.name)
        onComplete?(found, missing)
    }

    private func toolChip(_ tool: IdentifiedTool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: tool.isFound ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(tool.isFound ? Theme.brandSecondary : Theme.textTertiary)
            Text(tool.name)
                .font(Theme.caption)
                .foregroundStyle(tool.isFound ? Theme.textPrimary : Theme.textSecondary)
            // Shop button for missing tools
            if !tool.isFound {
                ShopButton(toolName: tool.name)
            }
        }
        .padding(.horizontal, Theme.spacingS)
        .padding(.vertical, 6)
        .background(
            tool.isFound
                ? Theme.brandSecondary.opacity(0.15)
                : Tool.isMissingCritical(tool) ? Theme.dangerRed.opacity(0.15) : Color.white.opacity(0.06),
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(
                tool.isFound ? Theme.brandSecondary.opacity(0.4) : Color.white.opacity(0.12),
                lineWidth: 1
            )
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: tool.isFound)
    }
}

// MARK: – Shop button (triggers App Intent)

private struct ShopButton: View {
    let toolName: String

    var body: some View {
        Button {
            // Open hardware store search — handled by App Intent in Phase 3
            let query = toolName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? toolName
            if let url = URL(string: "https://www.amazon.com/s?k=\(query)+tool&tag=\(Config.amazonPartnerTag)") {
                UIApplication.shared.open(url)
            }
        } label: {
            Text("Shop")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.brandPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.brandPrimary.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: – Helpers

private enum Tool {
    static func isMissingCritical(_ tool: IdentifiedTool) -> Bool {
        let name = tool.name.lowercased()
        // The legendary 10mm
        return name.contains("10mm") || name.contains("10 mm")
    }
}

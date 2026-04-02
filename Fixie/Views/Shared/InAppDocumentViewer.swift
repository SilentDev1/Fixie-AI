// Views/Shared/InAppDocumentViewer.swift
// In-app document/image viewer using WKWebView.
// Works correctly inside SwiftUI sheets (unlike SFSafariViewController).
// Handles images (PNG, JPG) and PDFs served from Firebase Storage.
import SwiftUI
import WebKit

struct InAppDocumentViewer: View {
    let url:   URL
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var loadError: String? = nil

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()

            VStack(spacing: 0) {
                // Nav bar
                HStack {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Theme.spacingM)
                .padding(.vertical, Theme.spacingM)

                Divider().background(.white.opacity(0.08))

                ZStack {
                    WebViewRepresentable(
                        url:       url,
                        isLoading: $isLoading,
                        loadError: $loadError
                    )

                    if isLoading {
                        VStack(spacing: Theme.spacingM) {
                            ProgressView()
                                .tint(Color(hex: 0x2979FF))
                                .scaleEffect(1.4)
                            Text("Loading certificate…")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hex: 0x0D0D0F))
                    }

                    if let error = loadError {
                        VStack(spacing: Theme.spacingM) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(Theme.warningAmber)
                            Text("Couldn't load certificate")
                                .font(Theme.bodyBold)
                                .foregroundStyle(Theme.textPrimary)
                            Text(error)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(Theme.spacingL)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hex: 0x0D0D0F))
                    }
                }
            }
        }
    }
}

// MARK: – WKWebView wrapper

private struct WebViewRepresentable: UIViewRepresentable {
    let url:       URL
    @Binding var isLoading: Bool
    @Binding var loadError: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.backgroundColor    = UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        wv.scrollView.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebViewRepresentable
        init(_ parent: WebViewRepresentable) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.loadError = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.loadError = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.loadError = error.localizedDescription
        }
    }
}

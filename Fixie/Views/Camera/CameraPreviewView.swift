// Views/Camera/CameraPreviewView.swift
import SwiftUI
import AVFoundation

/// UIViewRepresentable that hosts an AVCaptureVideoPreviewLayer.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> _PreviewView {
        let view = _PreviewView()
        view.previewLayer.session      = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: _PreviewView, context: Context) {}

    /// Nil out the session on the preview layer when SwiftUI removes the view.
    /// This releases the AVCaptureSession's XPC connection cleanly and suppresses
    /// the FigCaptureSourceRemote err=-17281 assertion that fires when the layer
    /// is deallocated while still holding an active session reference.
    static func dismantleUIView(_ uiView: _PreviewView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }

    final class _PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        // Keep the preview layer filling the view's bounds whenever layout changes.
        // Without this, the layer can remain zero-sized / gray on first appearance.
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }
}

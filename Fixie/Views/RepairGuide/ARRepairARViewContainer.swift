// Views/RepairGuide/ARRepairARViewContainer.swift
// UIViewRepresentable wrapper giving full ARKit raycast access.
import SwiftUI
import RealityKit
import ARKit

// MARK: – Coordinator (NSObject, actor-isolated via Task hops)

@MainActor
final class ARRepairCoordinator: NSObject {

    var arView: ARView?
    private var markerEntity: ModelEntity?
    private var markerAnchor: AnchorEntity?
    private var isLocked = false
    var onLockedChanged: ((Bool) -> Void)?

    // MARK: – Session setup

    func setup(in view: ARView) {
        self.arView = view

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]

        // LiDAR mesh reconstruction — enables precise sticky-lock
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            view.debugOptions = []  // remove .showSceneUnderstanding in prod
        }

        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        view.environment.lighting.intensityExponent = 1.8

        markerEntity = makeRepairMarker()
    }

    // MARK: – Marker update from Gemini bounding box + ARKit raycast

    /// Projects the normalized bounding-box center onto the real world via ARKit raycast.
    /// Prefers LiDAR mesh geometry; falls back to estimated plane.
    /// On first successful hit, "sticky-locks" the marker to that surface.
    func updateMarker(box: PartBoundingBox, label: String?) {
        guard let arView, !isLocked else { return }

        let screenPt = CGPoint(
            x: box.centerX * arView.bounds.width,
            y: box.centerY * arView.bounds.height
        )

        // Try mesh first (requires LiDAR), fall back to estimated plane
        let hitResults: [ARRaycastResult] = {
            let mesh = arView.raycast(from: screenPt,
                                      allowing: .existingPlaneGeometry,
                                      alignment: .any)
            return mesh.isEmpty
                ? arView.raycast(from: screenPt, allowing: .estimatedPlane, alignment: .any)
                : mesh
        }()

        guard let hit = hitResults.first else { return }

        if let anchor = markerAnchor {
            // Smooth translation
            anchor.move(to: Transform(matrix: hit.worldTransform),
                        relativeTo: nil, duration: 0.35,
                        timingFunction: .easeInOut)
        } else {
            let anchor = AnchorEntity(world: hit.worldTransform)
            if let m = markerEntity { anchor.addChild(m) }
            arView.scene.addAnchor(anchor)
            markerAnchor = anchor
        }
    }

    /// Locks marker to current position and triggers haptic.
    func lockMarker() {
        guard !isLocked else { return }
        isLocked = true
        onLockedChanged?(true)

        // Pulse the marker to show it's locked
        markerEntity?.scale = [1.3, 1.3, 1.3]
        markerEntity?.move(to: Transform(scale: .one),
                           relativeTo: markerEntity,
                           duration: 0.4,
                           timingFunction: .easeOut)

        // Step-complete haptic
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.prepare()
        haptic.impactOccurred()
    }

    func unlockMarker() {
        isLocked = false
        onLockedChanged?(false)
    }

    func triggerStepCompleteHaptic() {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.prepare()
        haptic.impactOccurred(intensity: 0.9)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            haptic.impactOccurred(intensity: 0.5)
        }
    }

    // MARK: – Marker construction

    private func makeRepairMarker() -> ModelEntity {
        // Outer thin disc as ring substitute (MeshResource.generateTorus unavailable on iOS)
        var ringMat = UnlitMaterial()
        ringMat.color = .init(tint: UIColor(red: 0, green: 0.478, blue: 1, alpha: 0.85))
        let outerMesh = MeshResource.generateCylinder(height: 0.004, radius: 0.055)
        let ring = ModelEntity(mesh: outerMesh, materials: [ringMat])

        // Inner disc mask (slightly smaller, offset up to create ring illusion)
        var maskMat = UnlitMaterial()
        maskMat.color = .init(tint: UIColor(white: 0, alpha: 0))
        let innerMesh = MeshResource.generateCylinder(height: 0.006, radius: 0.040)
        let inner = ModelEntity(mesh: innerMesh, materials: [maskMat])
        ring.addChild(inner)

        // Center dot
        let dotMesh = MeshResource.generateSphere(radius: 0.010)
        var dotMat = UnlitMaterial()
        dotMat.color = .init(tint: .systemBlue)
        let dot = ModelEntity(mesh: dotMesh, materials: [dotMat])

        // Point light for glow
        let lightComp = PointLightComponent(color: .blue, intensity: 2500, attenuationRadius: 0.5)
        let lightEntity = Entity()
        lightEntity.components[PointLightComponent.self] = lightComp

        ring.addChild(dot)
        ring.addChild(lightEntity)
        return ring
    }
}

// MARK: – UIViewRepresentable

struct ARRepairARViewContainer: UIViewRepresentable {

    @Binding var boundingBox: PartBoundingBox?
    @Binding var isLocked: Bool
    let stepLabel: String?
    let onCoordinatorReady: (ARRepairCoordinator) -> Void

    func makeCoordinator() -> ARRepairCoordinator {
        ARRepairCoordinator()
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        context.coordinator.setup(in: arView)
        context.coordinator.onLockedChanged = { locked in
            Task { @MainActor in isLocked = locked }
        }
        onCoordinatorReady(context.coordinator)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        if let box = boundingBox {
            context.coordinator.updateMarker(box: box, label: stepLabel)
        }
    }
}

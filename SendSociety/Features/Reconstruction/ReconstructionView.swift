import SwiftUI
import RealityKit
import ARKit
import simd

/// Step 4 — Generate the static 3D view. Non-AR RealityKit scene (no live camera passthrough):
/// the previously-scanned wall mesh + a single-frame skeleton, rendered together in the same
/// coordinate space, with one-finger drag-to-orbit. Static frame only — no animation, no
/// playback, no skeleton dragging (explicitly out of scope for this phase).
struct ReconstructionView: View {
    let wallAnchors: [ARMeshAnchor]
    let poseSample: BodyPoseSample?
    let cameraTransform: simd_float4x4
    let poseError: String?

    var body: some View {
        ZStack(alignment: .top) {
            ReconstructionSceneView(wallAnchors: wallAnchors, poseSample: poseSample, cameraTransform: cameraTransform)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 4) {
                Text("Step 4 — Static 3D Reconstruction").font(.headline)
                Text("One-finger drag to orbit. Single static frame — no animation or playback.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let poseError {
                    Text(poseError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
    }
}

private struct ReconstructionSceneView: UIViewRepresentable {
    let wallAnchors: [ARMeshAnchor]
    let poseSample: BodyPoseSample?
    let cameraTransform: simd_float4x4

    func makeUIView(context: Context) -> ARView {
        // cameraMode: .nonAR — a plain 3D scene, not a live camera-passthrough AR view.
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.black)

        let contentAnchor = AnchorEntity(world: .zero)
        contentAnchor.addChild(ReconstructionEntityBuilder.wallEntity(from: wallAnchors))
        if let poseSample {
            contentAnchor.addChild(ReconstructionEntityBuilder.skeletonEntity(from: poseSample, cameraTransform: cameraTransform))
        }
        view.scene.addAnchor(contentAnchor)

        let cameraEntity = PerspectiveCamera()
        cameraEntity.camera.fieldOfViewInDegrees = 60
        let cameraAnchor = AnchorEntity(world: .zero)
        cameraAnchor.addChild(cameraEntity)
        view.scene.addAnchor(cameraAnchor)

        context.coordinator.cameraEntity = cameraEntity
        context.coordinator.orbitCenter = boundingCenter()
        context.coordinator.updateCameraTransform()

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func boundingCenter() -> SIMD3<Float> {
        guard !wallAnchors.isEmpty else { return .zero }
        // Rough centroid from anchor transforms — good enough for framing an orbit camera in
        // this MVP, not a tight bounding-box fit.
        let positions = wallAnchors.map { anchor -> SIMD3<Float> in
            let t = anchor.transform.columns.3
            return SIMD3<Float>(t.x, t.y, t.z)
        }
        let sum = positions.reduce(SIMD3<Float>.zero, +)
        return sum / Float(positions.count)
    }

    final class Coordinator: NSObject {
        weak var cameraEntity: PerspectiveCamera?
        var orbitCenter: SIMD3<Float> = .zero
        var azimuth: Float = 0
        var elevation: Float = 0.3
        var radius: Float = 2.5

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            azimuth -= Float(translation.x) * 0.005
            elevation = max(-1.4, min(1.4, elevation - Float(translation.y) * 0.005))
            gesture.setTranslation(.zero, in: gesture.view)
            updateCameraTransform()
        }

        func updateCameraTransform() {
            guard let cameraEntity else { return }
            let x = orbitCenter.x + radius * cos(elevation) * sin(azimuth)
            let y = orbitCenter.y + radius * sin(elevation)
            let z = orbitCenter.z + radius * cos(elevation) * cos(azimuth)
            let position = SIMD3<Float>(x, y, z)
            cameraEntity.position = position
            cameraEntity.look(at: orbitCenter, from: position, relativeTo: nil)
        }
    }
}

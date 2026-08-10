import SwiftUI
import ARKit
import RealityKit

/// Thin SwiftUI wrapper around a RealityKit ARView (live camera passthrough), used as the live
/// camera + mesh-wireframe viewer for Steps 1-3. It attaches to the SAME ARSession the rest of
/// the app shares (via ARSessionManager) — it does not create or own its own session, and never
/// calls `session.run(...)` itself.
///
/// NOTE: this was originally built on SceneKit's `ARSCNView`, but `.showSceneUnderstanding` is
/// NOT a member of `ARSCNDebugOptions` (SceneKit) — it only exists on RealityKit's
/// `ARView.DebugOptions`. That's a real API gap, not an iOS-version issue: SceneKit's ARKit
/// integration has no built-in scene-reconstruction-mesh debug overlay at all. Switched to
/// RealityKit's `ARView` (cameraMode: .ar, i.e. live passthrough) to get the built-in wireframe
/// for free, which also keeps the app on one 3D framework end-to-end (Step 4 already uses
/// RealityKit's `ARView` in its non-AR mode).
struct ARMeshSceneView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        // Built-in RealityKit debug overlay: renders the live scene-reconstruction mesh as a
        // wireframe over the camera feed. This is the "visible scan progress" cue for Step 1 —
        // deliberately not building a custom mesh renderer for this MVP.
        view.debugOptions = [.showSceneUnderstanding]
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Session lifecycle is owned by ARSessionManager; nothing to push per SwiftUI refresh.
    }
}

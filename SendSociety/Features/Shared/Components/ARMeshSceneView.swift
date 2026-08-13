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
    /// Whether to render the built-in RealityKit debug wireframe over the camera feed. OFF by
    /// default (`false`) — for an ordinary coach setting up a climb, the raw scene-reconstruction
    /// mesh is visual clutter, not useful information; what they actually need is a plain "is my
    /// current angle good enough" readiness cue (see `RecordingView`/`WallScanView`'s guidance
    /// text, driven by `ARSessionManager.depthConfidenceRatio`), not a wireframe to interpret
    /// themselves. Kept as a real toggle (not deleted) since seeing the raw mesh IS genuinely
    /// useful for a developer checking how well the mesh is holding up against a real wall — see
    /// `MeshToggleButton`/`DeveloperSettings.showMesh` for how a coach or developer flips this on.
    var showMesh: Bool = false

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        view.debugOptions = showMesh ? [.showSceneUnderstanding] : []
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Session lifecycle is owned by ARSessionManager; `debugOptions` is the one thing this
        // view needs to react to live, since `MeshToggleButton` can flip `showMesh` at any time
        // while this screen is already on-screen.
        uiView.debugOptions = showMesh ? [.showSceneUnderstanding] : []
    }
}

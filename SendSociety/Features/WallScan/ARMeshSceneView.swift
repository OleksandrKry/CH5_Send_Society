import SwiftUI
import ARKit
import SceneKit

/// Thin SwiftUI wrapper around ARSCNView, used as the live camera + mesh-wireframe viewer for
/// Steps 1-3. It attaches to the SAME ARSession the rest of the app shares (via
/// ARSessionManager) — it does not create or own its own session, and never calls
/// `session.run(...)` itself.
struct ARMeshSceneView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        // Built-in ARKit debug overlay: renders the live scene-reconstruction mesh as a
        // wireframe over the camera feed. This is the "visible scan progress" cue for Step 1 —
        // deliberately not building a custom mesh renderer for this MVP.
        view.debugOptions = [.showSceneUnderstanding]
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Session lifecycle is owned by ARSessionManager; nothing to push per SwiftUI refresh.
    }
}

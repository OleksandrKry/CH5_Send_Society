import ARKit
import Combine
import simd

/// Owns the single, continuously-running ARSession shared across Steps 1-3.
///
/// CRITICAL: per the build brief, the wall scan and the recording MUST share one ARSession
/// instance. Restarting the session between steps forces ARKit to relocalize, and the wall's
/// coordinate space can drift out of alignment with the body's coordinate space — this MVP has
/// no fallback for that. `startIfNeeded()` is guarded so the session can only ever be started
/// once per app launch.
final class ARSessionManager: NSObject, ObservableObject, ARSessionDelegate {

    let session = ARSession()

    @Published private(set) var trackingQuality: TrackingQuality = .normal
    @Published private(set) var meshAnchors: [ARMeshAnchor] = []
    @Published private(set) var latestFrame: ARFrame?
    @Published private(set) var isRunning = false

    /// Low-level hook invoked synchronously on every frame update, used by Step 3 recording to
    /// feed frames into VideoRecorder. Deliberately not routed through @Published — ARFrame
    /// isn't Equatable, so a SwiftUI onChange-based approach would silently miss frames.
    var onFrameUpdate: ((ARFrame) -> Void)?

    private var didConfigure = false

    override init() {
        super.init()
        session.delegate = self
    }

    func startIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        if type(of: configuration).supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        configuration.environmentTexturing = .none
        configuration.planeDetection = [.horizontal, .vertical]

        session.run(configuration)
        isRunning = true
        DebugLog.general.info("ARSession started — one continuous session shared across Steps 1-3")
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestFrame = frame
        trackingQuality = Self.quality(for: frame.camera.trackingState)
        onFrameUpdate?(frame)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        ingest(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        ingest(anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let removedIDs = Set(anchors.compactMap { $0 as? ARMeshAnchor }.map { $0.identifier })
        guard !removedIDs.isEmpty else { return }
        meshAnchors.removeAll { removedIDs.contains($0.identifier) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DebugLog.tracking.error("ARSession failed: \(error.localizedDescription, privacy: .public)")
        trackingQuality = .notAvailable
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DebugLog.tracking.error("ARSession interrupted")
        trackingQuality = .notAvailable
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DebugLog.tracking.error("ARSession interruption ended — relocalizing (wall/body coordinate spaces may now be at risk)")
        trackingQuality = .relocalizing
    }

    private func ingest(_ anchors: [ARAnchor]) {
        let newMeshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !newMeshAnchors.isEmpty else { return }
        var byID = Dictionary(uniqueKeysWithValues: meshAnchors.map { ($0.identifier, $0) })
        for anchor in newMeshAnchors {
            byID[anchor.identifier] = anchor
        }
        meshAnchors = Array(byID.values)
    }

    private static func quality(for state: ARCamera.TrackingState) -> TrackingQuality {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .notAvailable
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return .limited("Move slower")
            case .insufficientFeatures: return .limited("Point at a more detailed area")
            case .initializing: return .limited("Hold steady — starting up")
            case .relocalizing: return .limited("Relocalizing — move slowly")
            @unknown default: return .limited("Hold steady")
            }
        }
    }

    /// Rough triangle count across all mesh anchors — the simple "scan progress" cue for Step 1.
    var estimatedTriangleCount: Int {
        meshAnchors.reduce(0) { $0 + $1.geometry.faces.count }
    }
}

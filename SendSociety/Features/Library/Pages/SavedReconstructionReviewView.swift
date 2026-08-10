import SwiftUI
import ARKit

/// Renders a single saved `ReconstructionEntry` directly — no Vision, no live ARKit session, just
/// `ReconstructionView`'s existing `initialWorldPositions`/`initialJointOverrides` loading path
/// (the same one `ContentView.ReconstructionHost` uses when the coach pauses back on an
/// already-generated moment within the SAME live pipeline run). This is what makes session review
/// possible without a live ARSession: the wall comes from the archived
/// `ARSessionManager.WallTextureReference` (see `WallScanArchive`), and the skeleton comes entirely
/// from the entry's already-grounded `worldPositions`.
///
/// Presented by `SessionReviewView` via `.fullScreenCover(item:)` — pulled into its own file since
/// it's a distinct, self-contained screen rather than a piece of that page's own layout.
struct SavedReconstructionReviewView: View {
    let entry: ReconstructionEntry
    let session: RecordingSession
    let sessionStore: SessionStore
    let wallTextureReference: ARSessionManager.WallTextureReference?
    let onClose: () -> Void

    var body: some View {
        ReconstructionView(
            // No live ARMeshAnchors in review (there's no live ARSession) — fine as long as the
            // archived textureReference has depth data, since `wallEntity` builds the full
            // point-cloud wall from that alone when it's available (see its doc comment).
            wallAnchors: [],
            wallTextureReference: wallTextureReference,
            poseSample: nil,
            // No live per-frame ARKit pose exists for a reviewed/reloaded reconstruction — nil (not
            // `matrix_identity_float4x4`) tells `ReconstructionView` there's no real recording
            // transform to seed the initial 3D-view camera from, so it falls back to the
            // bounding-box-based framing instead of a meaningless "camera at world origin" seed.
            cameraTransform: nil,
            depthContext: nil,
            leftGrip: entry.leftGrip,
            rightGrip: entry.rightGrip,
            leftFoot: entry.leftFoot,
            rightFoot: entry.rightFoot,
            leftGripOffsetSeconds: entry.leftGripOffsetSeconds,
            rightGripOffsetSeconds: entry.rightGripOffsetSeconds,
            leftFootOffsetSeconds: entry.leftFootOffsetSeconds,
            rightFootOffsetSeconds: entry.rightFootOffsetSeconds,
            poseError: nil,
            onBack: onClose,
            onFinished: onClose,
            initialAnnotationStrokes: entry.annotationStrokes,
            onAnnotationStrokesChanged: { strokes in
                var updated = entry
                updated.annotationStrokes = strokes
                session.upsertReconstruction(updated)
                sessionStore.save()
            },
            initialWorldPositions: entry.worldPositions,
            initialJointOverrides: entry.jointOverrides,
            onJointOverridesChanged: { overrides in
                var updated = entry
                updated.jointOverrides = overrides
                session.upsertReconstruction(updated)
                sessionStore.save()
            },
            isApproximate: entry.isApproximate
        )
    }
}

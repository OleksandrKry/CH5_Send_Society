import Foundation
import ARKit
import simd

/// Everything `ReconstructionView` needs to render Step 4's first frame — either loaded from an
/// already-saved 3D pose, or freshly detected via Vision. Plain data, no SwiftUI.
struct ReconstructionResult {
    /// The timestamp this result is actually for — may differ slightly from the originally
    /// requested moment if an existing saved entry nearby was loaded instead of that exact spot.
    let timestampSeconds: Double
    /// The stable "auto-detected baseline" positions — what every later joint-edit/annotation
    /// save writes on top of, never the coach's edits themselves.
    let baseWorldPositions: [BodyJointName: SIMD3<Float>]
    let initialWorldPositions: [BodyJointName: SIMD3<Float>]?
    let initialJointOverrides: [BodyJointName: SIMD3<Float>]?
    let initialAnnotationStrokes: [AnnotationStroke]
    let poseSample: BodyPoseSample?
    let cameraTransform: simd_float4x4?
    let depthContext: BodyPose3DExtractor.DepthGroundingContext?
    let poseError: String?
    /// True if this came from an already-saved reconstruction (Vision never ran); false if this
    /// is a brand-new detection.
    let wasLoadedFromSavedEntry: Bool
}

/// ReconstructionHostEngine is the "brain" behind Step 4's very first moment — deciding whether
/// to reload an already-saved 3D pose for this exact video moment, or run Vision fresh to detect
/// a new one, and packaging up everything `ReconstructionView` needs either way. It also knows
/// how to save the current reconstruction state back to disk. It does NOT import SwiftUI.
///
/// `@MainActor` because `save(...)` calls `SessionStore.save()`, which is itself
/// `@MainActor`-isolated (SwiftData's `ModelContext` isn't safe to touch off the main thread) —
/// this engine is only ever called from a View anyway (already on the main thread), so this just
/// tells the compiler what was already true.
@MainActor
enum ReconstructionHostEngine {
    /// How close (in seconds) the requested moment needs to be to an already-saved reconstruction
    /// before that saved one is loaded instead of running Vision again.
    static let savedEntryMatchWindowSeconds: Double = 0.3

    /// Loads a nearby saved reconstruction if one exists, otherwise runs Vision fresh via
    /// `LiveReconstructionGenerator` (Core/PoseReconstruction — the actual detection/grounding
    /// algorithm lives there, not here; this just decides WHICH path to take and packages up
    /// whichever result comes back).
    static func loadOrGenerate(
        input: ReconstructionInput,
        session: RecordingSession?,
        wallReference: ARSessionManager.WallTextureReference?
    ) -> ReconstructionResult {
        if let session, let existing = session.reconstructions.first(where: { abs($0.timestampSeconds - input.pausedSeconds) <= savedEntryMatchWindowSeconds }) {
            // This is a "load," not a "regenerate" — see `RecordingSession.swift`'s
            // `ReconstructionEntry` doc comment for why a NEW reconstruction at a previously-
            // unanalyzed timestamp isn't possible after the live AR session ends. That's not what's
            // happening here, since a saved entry for this exact spot already exists.
            DebugLog.reconstruction.info("Loaded saved reconstruction for t=\(existing.timestampSeconds, privacy: .public)s — skipping Vision")
            return ReconstructionResult(
                timestampSeconds: existing.timestampSeconds,
                baseWorldPositions: existing.worldPositions,
                initialWorldPositions: existing.worldPositions,
                initialJointOverrides: existing.jointOverrides,
                initialAnnotationStrokes: existing.annotationStrokes,
                poseSample: nil,
                cameraTransform: nil,
                depthContext: nil,
                poseError: nil,
                wasLoadedFromSavedEntry: true
            )
        }

        do {
            let generated = try LiveReconstructionGenerator.generate(input: input, wallReference: wallReference)
            return ReconstructionResult(
                timestampSeconds: input.pausedSeconds,
                baseWorldPositions: generated.worldPositions ?? [:],
                // Render from these FINAL positions directly (matching the loaded-saved-entry
                // path above), rather than leaving this nil and forcing `ReconstructionView` to
                // re-derive positions from `poseSample` itself.
                initialWorldPositions: generated.worldPositions,
                initialJointOverrides: nil,
                initialAnnotationStrokes: [],
                poseSample: generated.poseSample,
                cameraTransform: generated.cameraTransform,
                depthContext: generated.depthContext,
                poseError: generated.poseError,
                wasLoadedFromSavedEntry: false
            )
        } catch LiveReconstructionGenerator.GenerationError.noStoredFrameData {
            return failedResult(atVideoTime: input.pausedSeconds, message: "No stored depth/camera data for this moment in the video.")
        } catch LiveReconstructionGenerator.GenerationError.couldNotReadFrame {
            return failedResult(atVideoTime: input.pausedSeconds, message: "Couldn't read this frame from the recording — try a different moment in the video.")
        } catch {
            let description = String(describing: error)
            DebugLog.reconstruction.error("LiveReconstructionGenerator.generate threw an unexpected error: \(description, privacy: .public)")
            return failedResult(atVideoTime: input.pausedSeconds, message: "Something went wrong generating this reconstruction — try a different moment in the video.")
        }
    }

    private static func failedResult(atVideoTime videoTimeInSeconds: Double, message: String) -> ReconstructionResult {
        ReconstructionResult(
            timestampSeconds: videoTimeInSeconds,
            baseWorldPositions: [:],
            initialWorldPositions: nil,
            initialJointOverrides: nil,
            initialAnnotationStrokes: [],
            poseSample: nil,
            cameraTransform: nil,
            depthContext: nil,
            poseError: message,
            wasLoadedFromSavedEntry: false
        )
    }

    /// Writes the current in-memory reconstruction state (baseline + any edit/annotations) back
    /// into `session`. Does nothing if there's no session/store to save into (e.g. an earlier
    /// save failure — see `ContentView.currentSession`'s doc comment).
    static func save(
        session: RecordingSession?,
        sessionStore: SessionStore?,
        timestampSeconds: Double,
        baseWorldPositions: [BodyJointName: SIMD3<Float>],
        jointOverrides: [BodyJointName: SIMD3<Float>]?,
        annotationStrokes: [AnnotationStroke]
    ) {
        guard let session, let sessionStore else { return }
        let entry = ReconstructionEntry(
            timestampSeconds: timestampSeconds,
            worldPositions: baseWorldPositions,
            jointOverrides: jointOverrides,
            annotationStrokes: annotationStrokes
        )
        session.upsertReconstruction(entry)
        sessionStore.save()
    }
}

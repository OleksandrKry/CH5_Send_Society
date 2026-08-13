import CoreGraphics
import Foundation
import UIKit
import simd

/// Runs the full live Step 4 "Generate" pipeline for one paused video moment: real per-frame LiDAR
/// depth/camera-pose lookup and Vision body-pose detection — everything `ContentView`'s
/// `ReconstructionHost.generate()` used to do inline.
///
/// PULLED OUT ON PURPOSE, same reasoning as `ReconstructionEstimator`: this is the actual
/// pose-reconstruction algorithm, so it belongs in this module next to `BodyPose3DExtractor` /
/// `ReconstructionEntityBuilder`, not embedded in a SwiftUI view. `ReconstructionHost` is left
/// responsible only for its `@State` and rendering — it calls this once per "Generate" and copies
/// the result into its own state variables.
///
/// Unlike `ReconstructionEstimator` (which never has real depth), this path DOES have real LiDAR
/// data recorded during the live AR session (`RecordedFrameStore`) — see `Result`'s fields for how
/// that's threaded all the way through to world-position grounding.
enum LiveReconstructionGenerator {
    /// Thrown only for the two "nothing at all to work with" cases. A frame that reads fine but has
    /// no detectable body still produces a normal `Result` (with `poseSample == nil`), exactly like
    /// `ReconstructionEstimator`'s wall-only entries — see `Result.poseError`.
    enum GenerationError: Error {
        /// No `RecordedFrameData` exists near this playback moment at all — nothing to ground
        /// against, not even a camera transform.
        case noStoredFrameData
        /// Stored frame data exists, but the video file itself couldn't yield a frame image at this
        /// timestamp.
        case couldNotReadFrame
    }

    /// Everything `ReconstructionHost` needs to copy into its own `@State`. `cameraTransform` and
    /// `depthContext` are always real (never a placeholder) whenever this succeeds at all — even
    /// when no body was detected, since the wall-only view still benefits from a real camera seed
    /// (see `ContentView`'s original comments on why `recordingCameraTransform` exists separately
    /// from `cameraTransform`). `poseSample == nil` (with `poseError` set) is a legitimate,
    /// non-throwing outcome — mirrors `generate()`'s original "no climber detected" handling.
    struct Result {
        let cameraTransform: simd_float4x4
        let depthContext: BodyPose3DExtractor.DepthGroundingContext?
        let poseSample: BodyPoseSample?
        let poseError: String?
        /// nil exactly when no body was detected/grounded at all (`poseSample` nil). These are the
        /// FINAL world-space positions — `ContentView` must render from THIS field directly
        /// (`ReconstructionView.initialWorldPositions`) rather than re-deriving positions from
        /// `poseSample`.
        let worldPositions: [BodyJointName: SIMD3<Float>]?
    }

    /// Runs synchronously and can take a noticeable moment (frame extraction + up to 9 Vision calls
    /// total) — `ReconstructionHost.generate()` still owns dispatching appropriately, exactly as it
    /// did before this was extracted.
    static func generate(
        input: ReconstructionInput,
        wallReference: ARSessionManager.WallTextureReference?
    ) throws -> Result {
        guard let frameData = input.frameStore.nearestFrame(toPlaybackSeconds: input.pausedSeconds) else {
            let seconds = input.pausedSeconds
            DebugLog.reconstruction.error("No RecordedFrameData found near playback second \(seconds, privacy: .public)")
            throw GenerationError.noStoredFrameData
        }

        let cameraTransform = frameData.cameraTransform
        // Same real depth data the wall mesh itself was built from — this is what lets Step 4 place
        // the skeleton against the wall using real measurements instead of Vision's own (much less
        // reliable) depth estimate.
        let baseDepthContext = frameData.depthGroundingContext
        if baseDepthContext == nil {
            DebugLog.reconstruction.error("No depth data for this paused frame — skeleton placement will use Vision's raw (less accurate) estimate")
        }

        // `RecordedFrameStore` no longer keeps a live in-memory copy of every frame's color image
        // (that was the direct cause of an on-device OOM kill — 1.4GB resident after only ~11s of
        // recording; see that class's doc comment). Re-extract just the one frame actually needed,
        // straight from the video file `VideoRecorder` already wrote to disk — same raw/native pixel
        // layout `capturedImage` always was (see `VideoFrameExtractor`'s doc comment).
        guard let mainImage = VideoFrameExtractor.extractFrame(from: input.videoURL, atSeconds: input.pausedSeconds) else {
            let seconds = input.pausedSeconds
            DebugLog.reconstruction.error("VideoFrameExtractor returned nil at playback second \(seconds, privacy: .public)")
            throw GenerationError.couldNotReadFrame
        }

        // Attach the color frame just extracted above to the depth context for bilateral-weighted
        // depth grounding (see `BodyPose3DExtractor.LumaSource`'s doc comment) — this is the SAME
        // image already needed for Vision detection below, re-extracted from the saved video
        // specifically because `RecordedFrameData` deliberately never stores color itself. No-op
        // (stays nil) when there was no depth data at all for this frame.
        let depthContext = baseDepthContext?.withLumaSource(.cgImage(mainImage))

        var poseSample: BodyPoseSample?
        var poseError: String?
        do {
            // MUST use frameData's OWN stored orientation, not "current" — Step 4 can run minutes
            // after this frame was actually recorded, by which point the device may be held
            // completely differently. Using current orientation here was the real root cause of the
            // skeleton coming out rotated relative to the wall (see RecordedFrameData
            // .deviceOrientation's doc comment for the full story).
            poseSample = try BodyPose3DExtractor.detect(inVideoFrame: mainImage, deviceOrientation: frameData.deviceOrientation)
        } catch {
            poseError = "No body pose detected in this frame — try a different moment in the video."
            let description = String(describing: error)
            DebugLog.reconstruction.error("Body pose detection failed for reconstruction: \(description, privacy: .public)")
        }

        guard let poseSample else {
            // No body detected at all in this frame. `poseError` above already tells the coach to
            // try a different moment. Still a normal `Result`, not a throw — the camera
            // transform/depth above are real and usable for a wall-only view.
            return Result(
                cameraTransform: cameraTransform,
                depthContext: depthContext,
                poseSample: nil,
                poseError: poseError,
                worldPositions: nil
            )
        }

        let worldPositions = ReconstructionEntityBuilder.worldJointPositions(
            from: poseSample,
            cameraTransform: cameraTransform,
            depthContext: depthContext,
            wallReference: wallReference
        )

        return Result(
            cameraTransform: cameraTransform,
            depthContext: depthContext,
            poseSample: poseSample,
            poseError: nil,
            worldPositions: worldPositions
        )
    }
}

import CoreGraphics
import Foundation
import UIKit
import simd

/// Runs the full live Step 4 "Generate" pipeline for one paused video moment: real per-frame LiDAR
/// depth/camera-pose lookup, Vision body-pose detection, grip/foot classification, and (if any limb
/// classification comes back low-confidence) a nearby-frame fallback search — everything
/// `ContentView`'s `ReconstructionHost.generate()` used to do inline.
///
/// PULLED OUT ON PURPOSE, same reasoning as `ReconstructionEstimator`: this is the actual
/// pose-reconstruction algorithm, so it belongs in this module next to `BodyPose3DExtractor` /
/// `ReconstructionEntityBuilder`, not embedded in a SwiftUI view. `ReconstructionHost` is left
/// responsible only for its `@State` and rendering — it calls this once per "Generate" and copies
/// the result into its own state variables.
///
/// Unlike `ReconstructionEstimator` (which never has real depth), this path DOES have real LiDAR
/// data recorded during the live AR session (`RecordedFrameStore`) — see `Result`'s fields for how
/// that's threaded all the way through to hand classification and world-position grounding.
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
    /// from the classification-only `cameraTransform`). `poseSample == nil` (with `poseError` set)
    /// is a legitimate, non-throwing outcome — mirrors `generate()`'s original "no climber detected"
    /// handling.
    struct Result {
        let cameraTransform: simd_float4x4
        let depthContext: BodyPose3DExtractor.DepthGroundingContext?
        let poseSample: BodyPoseSample?
        let poseError: String?
        let leftGrip: GripClassification?
        let rightGrip: GripClassification?
        let leftFoot: FootClassification?
        let rightFoot: FootClassification?
        /// Non-nil only when the corresponding classification above was recovered from a nearby
        /// frame instead of the exact paused one — see the nearby-frame fallback search below.
        let leftGripOffsetSeconds: TimeInterval?
        let rightGripOffsetSeconds: TimeInterval?
        let leftFootOffsetSeconds: TimeInterval?
        let rightFootOffsetSeconds: TimeInterval?
        /// nil exactly when `poseSample` is nil (no body detected, nothing to ground).
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
        let depthContext = frameData.depthGroundingContext
        if depthContext == nil {
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
            // No body detected at all in this frame — nothing to classify grips/feet against
            // (classification needs real wrist/ankle world positions). `poseError` above already
            // tells the coach to try a different moment. Still a normal `Result`, not a throw — the
            // camera transform/depth above are real and usable for a wall-only view.
            return Result(
                cameraTransform: cameraTransform,
                depthContext: depthContext,
                poseSample: nil,
                poseError: poseError,
                leftGrip: nil,
                rightGrip: nil,
                leftFoot: nil,
                rightFoot: nil,
                leftGripOffsetSeconds: nil,
                rightGripOffsetSeconds: nil,
                leftFootOffsetSeconds: nil,
                rightFootOffsetSeconds: nil,
                worldPositions: nil
            )
        }

        // Grip/foot-placement classification replaces raw finger/toe reconstruction here — see
        // GripClassifier's doc comment for why. Hand landmarks (whatever Vision could detect, which
        // is often sparse or empty on an occluded grip) are still computed as an INPUT to
        // classification, same as before — they're just no longer rendered directly as raw fingertip
        // geometry.
        let mainHandSample: HandPoseSample? = depthContext.map {
            BodyPose3DExtractor.detectHands(inVideoFrame: mainImage, context: $0)
        }
        let mainClassification = ReconstructionEntityBuilder.classifyGripsAndFeet(
            poseSample: poseSample,
            cameraTransform: cameraTransform,
            depthContext: depthContext,
            handSample: mainHandSample,
            handCameraTransform: cameraTransform,
            wallReference: wallReference
        )
        var leftGrip = mainClassification.leftHand
        var rightGrip = mainClassification.rightHand
        var leftFoot = mainClassification.leftFoot
        var rightFoot = mainClassification.rightFoot
        var leftGripOffsetSeconds: TimeInterval?
        var rightGripOffsetSeconds: TimeInterval?
        var leftFootOffsetSeconds: TimeInterval?
        var rightFootOffsetSeconds: TimeInterval?

        func meets(_ c: GripClassification?) -> Bool { (c?.confidence ?? 0) >= GripClassifier.confidenceThreshold }
        func meetsFoot(_ c: FootClassification?) -> Bool { (c?.confidence ?? 0) >= GripClassifier.confidenceThreshold }

        // Same idea as the raw-hand nearby-frame fallback this replaces: a fully gripped/wedged limb
        // is close to worst-case for classification on the EXACT paused frame, so if any slot came
        // back low-confidence, search nearby moments in the same clip (the reach just before
        // contact, or the release just after, are the usual candidates) for a more confident answer
        // for THAT specific limb. Each candidate frame is analyzed (body pose + hands) ONCE and
        // reused across all four slots, rather than re-running Vision per slot — capped at 8
        // candidates to bound how many extra Vision calls one "Generate" tap can trigger.
        if !meets(leftGrip) || !meets(rightGrip) || !meetsFoot(leftFoot) || !meetsFoot(rightFoot) {
            let candidates = Array(input.frameStore.nearbyFrames(toPlaybackSeconds: input.pausedSeconds, withinSeconds: 1.5).prefix(8))
            for candidate in candidates {
                // Same on-demand video re-extraction as the main frame above — `candidate` no longer
                // carries its own `capturedImage`. `playbackSeconds(forTimestamp:)` converts its raw
                // ARKit timestamp back to a video-relative second.
                guard let candidateSeconds = input.frameStore.playbackSeconds(forTimestamp: candidate.timestamp),
                      let candidateImage = VideoFrameExtractor.extractFrame(from: input.videoURL, atSeconds: candidateSeconds),
                      let candidateDepthContext = candidate.depthGroundingContext,
                      let candidatePose = try? BodyPose3DExtractor.detect(inVideoFrame: candidateImage, deviceOrientation: candidate.deviceOrientation)
                else { continue }
                let candidateHands = BodyPose3DExtractor.detectHands(inVideoFrame: candidateImage, context: candidateDepthContext)
                let candidateClassification = ReconstructionEntityBuilder.classifyGripsAndFeet(
                    poseSample: candidatePose,
                    cameraTransform: candidate.cameraTransform,
                    depthContext: candidateDepthContext,
                    handSample: candidateHands,
                    handCameraTransform: candidate.cameraTransform,
                    wallReference: wallReference
                )
                let offset = candidate.timestamp - frameData.timestamp

                if !meets(leftGrip), meets(candidateClassification.leftHand) {
                    leftGrip = candidateClassification.leftHand
                    leftGripOffsetSeconds = offset
                }
                if !meets(rightGrip), meets(candidateClassification.rightHand) {
                    rightGrip = candidateClassification.rightHand
                    rightGripOffsetSeconds = offset
                }
                if !meetsFoot(leftFoot), meetsFoot(candidateClassification.leftFoot) {
                    leftFoot = candidateClassification.leftFoot
                    leftFootOffsetSeconds = offset
                }
                if !meetsFoot(rightFoot), meetsFoot(candidateClassification.rightFoot) {
                    rightFoot = candidateClassification.rightFoot
                    rightFootOffsetSeconds = offset
                }
            }
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
            leftGrip: leftGrip,
            rightGrip: rightGrip,
            leftFoot: leftFoot,
            rightFoot: rightFoot,
            leftGripOffsetSeconds: leftGripOffsetSeconds,
            rightGripOffsetSeconds: rightGripOffsetSeconds,
            leftFootOffsetSeconds: leftFootOffsetSeconds,
            rightFootOffsetSeconds: rightFootOffsetSeconds,
            worldPositions: worldPositions
        )
    }
}

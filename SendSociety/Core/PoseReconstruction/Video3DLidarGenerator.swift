//
//  Video3DLidarGenerator.swift
//  SendSociety
//
//  Created by Christofer Theodore on 15/08/26.
//
import CoreGraphics
import Foundation
import UIKit
import simd

enum Video3DLidarGenerator {
    enum GenerationError: Error {
        case noStoredFrameData
        case couldNotReadFrame
    }

    struct Result {
        let cameraTransform: simd_float4x4
        let depthContext: AppleVisionSkeletonExtractor.DepthGroundingContext?
        let appleVisionSkeleton: AppleVisionSkeleton?
        let poseError: String?
        /// nil exactly when no body was detected/grounded at all (`poseSample` nil). These are the
        /// FINAL world-space positions — `ContentView` must render from THIS field directly
        /// (`ReconstructionView.initialWorldPositions`) rather than re-deriving positions from
        /// `poseSample`.
        let appleVisionJoints: [BodyJointName: SIMD3<Float>]?
    }

    /// Runs synchronously and can take a noticeable moment (frame extraction + up to 9 Vision calls
    /// total) — `ReconstructionHost.generate()` still owns dispatching appropriately, exactly as it
    /// did before this was extracted.
    static func generate(
        input: Video3DLidarInput,
        wallReference: ARSessionManager.WallTextureReference?
        
    ) throws -> Result {
        guard let frameData = input.frameStore.nearestFrame(toPlaybackSeconds: input.timestampSeconds, clipStartTimestamp: input.clipStartTimestamp) else {
            let seconds = input.timestampSeconds
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
        guard let mainImage = VideoFrameExtractor.extractFrame(from: input.videoURL, atSeconds: input.timestampSeconds) else {
            let seconds = input.timestampSeconds
            DebugLog.reconstruction.error("VideoFrameExtractor returned nil at playback second \(seconds, privacy: .public)")
            throw GenerationError.couldNotReadFrame
        }

        // Attach the color frame just extracted above to the depth context for bilateral-weighted
        // depth grounding (see `BodyPose3DExtractor.LumaSource`'s doc comment) — this is the SAME
        // image already needed for Vision detection below, re-extracted from the saved video
        // specifically because `RecordedFrameData` deliberately never stores color itself. No-op
        // (stays nil) when there was no depth data at all for this frame.
        let depthContext = baseDepthContext?.withLumaSource(.cgImage(mainImage))

        var appleVisionSkeleton: AppleVisionSkeleton?
        var poseError: String?
        do {
            // MUST use frameData's OWN stored orientation, not "current" — Step 4 can run minutes
            // after this frame was actually recorded, by which point the device may be held
            // completely differently. Using current orientation here was the real root cause of the
            // skeleton coming out rotated relative to the wall (see RecordedFrameData
            // .deviceOrientation's doc comment for the full story).
            appleVisionSkeleton = try AppleVisionSkeletonExtractor.detect(inVideoFrame: mainImage, deviceOrientation: frameData.deviceOrientation)
        } catch {
            poseError = "No body pose detected in this frame — try a different moment in the video."
            let description = String(describing: error)
            DebugLog.reconstruction.error("Body pose detection failed for reconstruction: \(description, privacy: .public)")
        }

        guard let appleVisionSkeleton else {
            // No body detected at all in this frame. `poseError` above already tells the coach to
            // try a different moment. Still a normal `Result`, not a throw — the camera
            // transform/depth above are real and usable for a wall-only view.
            return Result(
                cameraTransform: cameraTransform,
                depthContext: depthContext,
                appleVisionSkeleton: nil,
                poseError: poseError,
                appleVisionJoints: nil
            )
        }

        let appleVisionJoint = Video3DRealityKit.generate3DJointPositions(
            from: appleVisionSkeleton,
            cameraTransform: cameraTransform,
            depthContext: depthContext,
            wallReference: wallReference
        )

        return Result(
            cameraTransform: cameraTransform,
            depthContext: depthContext,
            appleVisionSkeleton: appleVisionSkeleton,
            poseError: nil,
            appleVisionJoints: appleVisionJoint
        )
    }
}


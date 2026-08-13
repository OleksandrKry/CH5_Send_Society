import CoreGraphics
import Foundation
import UIKit
import simd

/// Builds a `ReconstructionEntry` from a saved video frame WITHOUT any live LiDAR depth — the
/// "Estimate 3D" path session review uses (`SessionReviewView`'s "Estimate 3D View" button) to
/// analyze a moment that was never grounded in real depth during the original recording.
///
/// PULLED OUT OF `SessionReviewView` ON PURPOSE: this is the actual pose-reconstruction algorithm
/// (frame extraction -> Vision -> classification -> entry), so it belongs in this module alongside
/// `BodyPose3DExtractor`/`ReconstructionEntityBuilder`, not inside a SwiftUI file. A frontend
/// developer editing `SessionReviewView`'s layout never needs to see or understand this; a backend
/// developer changing how estimation works never needs to touch SwiftUI.
///
/// See `ReconstructionEntry.isApproximate`'s doc comment for the full accuracy trade-off this
/// implies versus a live-generated (real LiDAR depth) reconstruction.
enum ReconstructionEstimator {
    /// Thrown only when there's no frame at all to analyze — anything past that point (including
    /// "no climber detected") still produces a usable `ReconstructionEntry` (see `estimate`'s doc
    /// comment), since a wall-only estimate is a legitimate, useful result on its own.
    enum EstimationError: Error {
        case couldNotReadFrame
    }

    /// Runs entirely synchronously and can take a noticeable moment (frame extraction + Vision are
    /// both slow enough to matter) — callers wanting this off the main thread should dispatch to a
    /// background queue themselves, exactly like `SessionReviewView.generateEstimate` does.
    ///
    /// `deviceOrientation` MUST be the orientation the phone was actually held in during the
    /// ORIGINAL recording (`RecordingSession.recordingDeviceOrientationRawValue`), never a fixed
    /// assumption — see `BodyPose3DExtractor.detect(inVideoFrame:deviceOrientation:)`'s doc comment
    /// for why getting this wrong is exactly what makes a re-generated posture face the wrong way.
    ///
    /// Returns a full, classified entry when a climber is detected; a WALL-ONLY entry (empty
    /// `worldPositions`, no grip/foot classification) when the frame reads fine but no body pose
    /// could be found — that's a legitimate result, not a failure, so the coach can still check
    /// wall-scan/camera-angle calibration without a person in frame (mirrors Step 4's live
    /// "Generate" behavior for the same situation). Only throws `EstimationError.couldNotReadFrame`
    /// when there's no frame to analyze at all.
    static func estimate(
        videoURL: URL,
        atSeconds timestamp: Double,
        deviceOrientation: UIDeviceOrientation,
        wallReference: ARSessionManager.WallTextureReference?,
        calibratedSegments: SegmentLengths? = nil
    ) throws -> ReconstructionEntry {
        guard let cgImage = VideoFrameExtractor.extractFrame(from: videoURL, atSeconds: timestamp) else {
            throw EstimationError.couldNotReadFrame
        }

        do {
            let poseSample = try BodyPose3DExtractor.detect(inVideoFrame: cgImage, deviceOrientation: deviceOrientation)
            // No real depth here (see this type's doc comment) — the wall's own archived reference
            // camera position stands in for "roughly where the camera was," which is only a
            // reasonable approximation if the camera didn't move much over the recording.
            //
            // ESTIMATE-3D-ONLY INITIAL ROTATION: this path (unlike live Step 4 generation) has no
            // real per-frame ARKit camera transform to place the skeleton with, so it's prone to
            // coming out rotated relative to the wall. `estimateInitialRotation` is a fixed 90°
            // correction about the camera's own local Z axis, applied here (not in
            // `ReconstructionEntityBuilder`) so it affects ONLY this Estimate 3D path — the
            // already-confirmed-correct live Generate 3D and saved-session-review paths never call
            // this function, so they're untouched.
            //
            // Post-multiplying (cameraTransform * rotation) rotates the LOCAL/camera-space axes
            // before they're mapped to world space via the wall's reference camera pose — try this
            // first since it's a coordinate-convention correction, not a "spin the world" effect.
            // If the skeleton comes out rotated the WRONG way on device: flip the sign to -.pi / 2,
            // or swap the multiplication order to `estimateInitialRotation * (wallReference?
            // .cameraTransform ?? matrix_identity_float4x4)` to rotate around the WORLD Z axis
            // instead — both are one-line changes to try, since there's no way to preview this
            // without rebuilding on hardware. Test via Library -> open a saved session -> pause on
            // a frame with the climber in it -> "Estimate 3D View".
            let estimateInitialRotation = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
            let approximateCameraTransform = (wallReference?.cameraTransform ?? matrix_identity_float4x4) * estimateInitialRotation

            let rawWorldPositions = ReconstructionEntityBuilder.worldJointPositions(
                from: poseSample,
                cameraTransform: approximateCameraTransform,
                depthContext: nil,
                wallReference: wallReference
            )

            // This path has NO real depth at all (see this type's doc comment), so it's the most
            // likely of the two generation paths to have bone-proportion errors — see
            // `CalibrationScaleCorrection`'s doc comment. No-ops when `calibratedSegments` is nil
            // (Step 2 was skipped for this session).
            let worldPositions = CalibrationScaleCorrection.retargeted(rawWorldPositions, toMatch: nil)
            // Hand classification needs real depth-grounded hand joints (`handSample: nil` here),
            // so both hands always come back nil -> rendered as an honest "uncertain" marker. Foot
            // classification only needs body-joint geometry, so it still runs. Classifies against
            // the same PRE-retargeting positions the poseSample-based overload would have used
            // (retargeting is a display/measurement correction, not something classification here
            // has ever accounted for).
            let classification = ReconstructionEntityBuilder.classifyGripsAndFeet(
                poseSample: poseSample,
                cameraTransform: approximateCameraTransform,
                depthContext: nil,
                handSample: nil,
                handCameraTransform: nil,
                wallReference: wallReference
            )
            return ReconstructionEntry(
                timestampSeconds: timestamp,
                worldPositions: worldPositions,
                jointOverrides: nil,
                leftGrip: classification.leftHand,
                rightGrip: classification.rightHand,
                leftFoot: classification.leftFoot,
                rightFoot: classification.rightFoot,
                annotationStrokes: [],
                isApproximate: true
            )
        } catch {
            // No climber detected — still return a WALL-ONLY entry rather than propagating the
            // error, so the coach can check wall-scan/camera-angle calibration in isolation, a
            // normal and useful thing to do on its own. `ReconstructionView` already renders fine
            // with an empty `worldPositions` dict.
            return ReconstructionEntry(
                timestampSeconds: timestamp,
                worldPositions: [:],
                jointOverrides: nil,
                leftGrip: nil,
                rightGrip: nil,
                leftFoot: nil,
                rightFoot: nil,
                leftGripOffsetSeconds: nil,
                rightGripOffsetSeconds: nil,
                leftFootOffsetSeconds: nil,
                rightFootOffsetSeconds: nil,
                annotationStrokes: [],
                isApproximate: true
            )
        }
    }
}

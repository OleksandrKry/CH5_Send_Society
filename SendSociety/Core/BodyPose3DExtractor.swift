import Vision
import ARKit
import simd
import UIKit

/// Output of a single VNDetectHumanBodyPose3DRequest call.
struct BodyPoseSample {
    /// Joint positions as returned by Vision: translation relative to the skeleton's root
    /// joint (center of the hip), in meters.
    var rootRelativePositions: [BodyJointName: SIMD3<Float>]
    var confidences: [BodyJointName: Float]
    /// Apple: "a transform from the skeleton hip to the camera." Needed to place joints into
    /// ARKit world space — see `worldPosition(rootRelative:cameraOriginMatrix:cameraTransform:)`.
    var cameraOriginMatrix: simd_float4x4
    var bodyHeight: Float
}

enum BodyPoseError: Error {
    case noPersonDetected
    case visionRequestFailed(Error)
}

enum BodyPose3DExtractor {

    private static let jointMap: [(BodyJointName, VNHumanBodyPose3DObservation.JointName)] = [
        (.centerHead, .centerHead), (.topHead, .topHead),
        (.centerShoulder, .centerShoulder), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.spine, .spine), (.root, .root),
        (.leftHip, .leftHip), (.rightHip, .rightHip),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
        (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle),
    ]

    /// Runs VNDetectHumanBodyPose3DRequest on a single camera frame.
    ///
    /// NOTE on depth — read before "fixing" this: we deliberately do NOT thread ARKit's
    /// `ARDepthData` (from `ARFrame.sceneDepth`) into `VNImageRequestHandler`'s `depthData:`
    /// parameter. That parameter expects `AVDepthData`, and there is no stable, documented
    /// conversion from `ARDepthData` (LiDAR scene depth) to `AVDepthData` (camera-capture
    /// depth) — shipping a hand-rolled bridge for that would be unverified guesswork. Instead:
    /// Vision's 3D request produces its own metric-scale estimate from the color image alone,
    /// and we separately combine its output with ARKit's own per-frame depth map + camera
    /// transform for the world-space alignment work in Step 4. This split is a known, flagged
    /// open question to validate on real hardware (see success criterion #4 in the brief).
    static func detect(in pixelBuffer: CVPixelBuffer) throws -> BodyPoseSample {
        let request = VNDetectHumanBodyPose3DRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: cameraOrientation(),
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            throw BodyPoseError.visionRequestFailed(error)
        }
        guard let observation = request.results?.first else {
            throw BodyPoseError.noPersonDetected
        }

        var positions: [BodyJointName: SIMD3<Float>] = [:]
        var confidences: [BodyJointName: Float] = [:]
        for (ours, vision) in jointMap {
            guard let point = try? observation.recognizedPoint(vision) else { continue }
            let translation = point.position.columns.3
            positions[ours] = SIMD3<Float>(translation.x, translation.y, translation.z)
            confidences[ours] = Float(point.confidence)
        }

        return BodyPoseSample(
            rootRelativePositions: positions,
            confidences: confidences,
            cameraOriginMatrix: observation.cameraOriginMatrix,
            bodyHeight: observation.bodyHeight
        )
    }

    /// Converts a root-relative joint position into ARKit world space, using the SAME frame's
    /// camera transform the pose was detected on.
    ///
    /// Composition: world = cameraTransform * cameraOriginMatrix * rootRelativePoint.
    /// `cameraOriginMatrix` is documented by Apple as "a transform from the skeleton hip to the
    /// camera" — by ARKit's own naming convention (an X-to-Y transform maps points FROM X-space
    /// TO Y-space, e.g. ARCamera.transform maps camera space to world space), that reads as
    /// hip-space -> camera-space. This composition is the highest-risk piece of math in the
    /// whole pipeline — it determines whether the reconstructed hand actually lands on the hold
    /// the climber was touching. VERIFY ON REAL HARDWARE (success criterion #4); if the skeleton
    /// is offset/rotated relative to the wall mesh in Step 4, this is the first place to look.
    static func worldPosition(
        rootRelative: SIMD3<Float>,
        cameraOriginMatrix: simd_float4x4,
        cameraTransform: simd_float4x4
    ) -> SIMD3<Float> {
        let local = SIMD4<Float>(rootRelative.x, rootRelative.y, rootRelative.z, 1)
        let cameraSpace = cameraOriginMatrix * local
        let world = cameraTransform * cameraSpace
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    /// Standard mapping for ARKit's back-camera `capturedImage` buffer (native landscape-right
    /// sensor orientation) into the orientation Vision expects, based on current UI orientation.
    private static func cameraOrientation() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        case .portraitUpsideDown: return .left
        default: return .right
        }
    }
}

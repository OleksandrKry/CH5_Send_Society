import ARKit
import UIKit
import simd

/// Runs Vision body-pose detection + LiDAR grounding for one `ARFrame` during a `CalibrationView`
/// capture session, and decides what should happen with the result — pulled out of `CalibrationView`
/// so the actual per-frame processing algorithm lives in this module (not embedded in a SwiftUI
/// `Timer` callback), leaving the View responsible only for driving its 15Hz `Timer` loop and
/// updating its own state from whatever `Result` comes back.
enum CalibrationFrameProcessor {
    /// Locked in on the first usable frame of a capture session and held for the rest of that
    /// session — `CalibrationEngine` averages joint positions across frames, so every ingested
    /// frame in one session MUST be in the same coordinate space; mixing LiDAR-grounded absolute
    /// camera-space positions with Vision-only root-relative positions across frames would silently
    /// corrupt the average. See `CalibrationView.groundingMode`.
    enum GroundingMode {
        case grounded
        case ungrounded
    }

    enum Result {
        /// Positions ready to feed into `CalibrationEngine.ingest(_:)`, tagged with the grounding
        /// mode that produced them. Only meaningful to actually LOCK the caller's own state the
        /// first time this comes back with `lockedGroundingMode == nil` going in — every call after
        /// that should keep passing the same locked mode back in (see `GroundingMode`'s doc comment
        /// for why this can't be re-decided per frame).
        case positions([BodyJointName: SIMD3<Float>], groundingMode: GroundingMode)
        /// Session is committed to `.grounded` mode but this particular frame didn't ground — the
        /// caller should skip this frame (not ingest anything) rather than mixing coordinate
        /// spaces into the average.
        case trackingDip
        case noPersonDetected
        case error(String)
    }

    /// `lockedGroundingMode` should only be `nil` for the first frame of a capture session — pass
    /// back whatever `groundingMode` a `.positions` result carried on every subsequent call.
    static func process(
        frame: ARFrame,
        deviceOrientation: UIDeviceOrientation,
        lockedGroundingMode: GroundingMode?
    ) -> Result {
        let sample: BodyPoseSample
        do {
            sample = try BodyPose3DExtractor.detect(in: frame.capturedImage, deviceOrientation: deviceOrientation)
        } catch BodyPoseError.noPersonDetected {
            return .noPersonDetected
        } catch {
            return .error(error.localizedDescription)
        }

        // Ground every joint in real LiDAR depth instead of trusting Vision's own depth/scale
        // estimate (the known-weak axis for single-view 3D pose — see
        // BodyPose3DExtractor.lidarGroundedCameraSpacePosition for why).
        let context = BodyPose3DExtractor.DepthGroundingContext.from(frame: frame, deviceOrientation: deviceOrientation)
        let grounded = context.flatMap {
            BodyPose3DExtractor.groundAllJoints(sample.rootRelativePositions, cameraOriginMatrix: sample.cameraOriginMatrix, context: $0)
        }

        let mode = lockedGroundingMode ?? (grounded != nil ? .grounded : .ungrounded)

        switch mode {
        case .grounded:
            // Committed to grounded mode (either just now, or on an earlier frame this session)
            // but this particular frame didn't ground — the caller must not mix in an ungrounded
            // sample here.
            guard let grounded else { return .trackingDip }
            return .positions(grounded, groundingMode: .grounded)
        case .ungrounded:
            return .positions(sample.rootRelativePositions, groundingMode: .ungrounded)
        }
    }
}

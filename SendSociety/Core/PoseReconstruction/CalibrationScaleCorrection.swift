import Foundation
import simd

/// Corrects a freshly-generated skeleton's overall scale/position using the climber's Step 2
/// `CalibrationResult`, if one exists for this session.
///
/// PROBLEM THIS SOLVES: Step 2 measures the climber's real height once, in a controlled T-pose at
/// a known distance. Step 4's live "Generate" and Session Review's "Estimate 3D" each detect a
/// BRAND NEW skeleton from a single video frame, at whatever camera angle/distance that frame
/// happened to be recorded from — completely independent of Step 2's measurement. Before this
/// type existed, that measurement was captured and saved and then never read again (see
/// `RecordingSession.calibration`'s doc comment) — every generated skeleton's scale came entirely
/// from that one frame's own Vision detection + whatever LiDAR grounding was available, with
/// nothing to correct it against. On a frame where grounding is weak or entirely absent (Estimate
/// 3D never has real depth at all — see `ReconstructionEstimator`), the skeleton can come out the
/// wrong size, which is what pushes it visibly into the wall or floor relative to the real,
/// true-to-scale LiDAR wall mesh.
///
/// FIX: after a skeleton's world positions are computed, compare its own detected height (topHead
/// -> lower ankle, the SAME two joints and formula `CalibrationEngine` uses) against the climber's
/// calibrated height, and uniformly rescale every joint around the ankle if they disagree by more
/// than a small tolerance. Anchoring on the ankle (rather than the world origin) keeps the
/// climber's feet wherever LiDAR/Vision actually placed them — only the skeleton's overall SIZE
/// changes, not its grounded contact point.
enum CalibrationScaleCorrection {
    /// Below this, detected/calibrated agreement is close enough that rescaling would just add
    /// floating-point noise for no visible benefit.
    private static let agreementTolerance: Float = 0.03
    /// Scale factors outside this range aren't trusted as "the calibrated height correcting a
    /// scale error" — more likely a bad detection (wrong person, partial occlusion, degenerate
    /// pose) that rescaling would make worse, not better, so it's left alone instead.
    private static let minTrustedScale: Float = 0.5
    private static let maxTrustedScale: Float = 2.0

    /// Recomputes height exactly the way `CalibrationEngine.deriveSegments` does, so it's directly
    /// comparable to `CalibrationResult.segments.height`.
    static func detectedHeightMeters(from worldPositions: [BodyJointName: SIMD3<Float>]) -> Float? {
        guard let head = worldPositions[.topHead],
              let leftAnkle = worldPositions[.leftAnkle],
              let rightAnkle = worldPositions[.rightAnkle]
        else { return nil }
        let ankle = leftAnkle.y < rightAnkle.y ? leftAnkle : rightAnkle
        return simd_distance(head, ankle)
    }

    /// Returns `worldPositions` rescaled to match `calibratedHeightMeters`, or unchanged if there's
    /// nothing to correct against (no calibration for this session, no detectable height in this
    /// frame, or the implied scale factor falls outside a plausible range — see the tolerances
    /// above). Safe to call with `calibratedHeightMeters: nil` (e.g. Step 2 was skipped for this
    /// session) — always a no-op in that case.
    static func rescaled(
        _ worldPositions: [BodyJointName: SIMD3<Float>],
        toMatchCalibratedHeightMeters calibratedHeightMeters: Float?
    ) -> [BodyJointName: SIMD3<Float>] {
        guard let calibratedHeightMeters, calibratedHeightMeters > 0,
              let detected = detectedHeightMeters(from: worldPositions), detected > 0.05
        else { return worldPositions }

        guard abs(detected - calibratedHeightMeters) / calibratedHeightMeters > agreementTolerance else {
            return worldPositions
        }

        let scale = calibratedHeightMeters / detected
        guard scale > minTrustedScale, scale < maxTrustedScale else {
            DebugLog.reconstruction.error("Calibration scale correction skipped — implied scale \(scale, privacy: .public) is outside the trusted range, detection likely unreliable")
            return worldPositions
        }

        guard let leftAnkle = worldPositions[.leftAnkle], let rightAnkle = worldPositions[.rightAnkle] else {
            return worldPositions
        }
        let anchor = leftAnkle.y < rightAnkle.y ? leftAnkle : rightAnkle

        var scaled: [BodyJointName: SIMD3<Float>] = [:]
        for (joint, position) in worldPositions {
            scaled[joint] = anchor + (position - anchor) * scale
        }
        DebugLog.reconstruction.info("Calibration scale correction applied — detected height \(detected, privacy: .public)m vs calibrated \(calibratedHeightMeters, privacy: .public)m, scale=\(scale, privacy: .public)")
        return scaled
    }
}

import Foundation
import simd

/// Corrects a freshly-generated skeleton's individual BONE LENGTHS using the climber's Step 2
/// `CalibrationResult` (upper arm / forearm / thigh / shin / torso), treating that measurement as
/// the source of truth for how long each limb segment should be.
///
/// PROBLEM THIS SOLVES: a single video frame's Vision detection (even when LiDAR-grounded) can
/// place an individual joint slightly wrong without the whole skeleton looking obviously broken —
/// e.g. an elbow detected a bit too close to the shoulder, or a wrist detected too far from the
/// elbow. The visible result is a forearm that's 2-3x longer than the upper arm, or a shin longer
/// than the thigh, even on a frame where the skeleton's overall size looks roughly right. An
/// earlier version of this type only compared overall HEIGHT and rescaled the whole skeleton by
/// one factor — that fixes gross scale errors but can never fix a RATIO problem between two bones,
/// since every joint gets the same correction.
///
/// FIX: walk the skeleton from `.root` outward, following the same `skeletonBones` parent/child
/// tree `SkeletonPoseEditor` uses for constrained dragging (Core/Models.swift). For every bone
/// with a known calibrated length (upper arm, forearm, thigh, shin — torso is handled specially,
/// see `retargeted`'s implementation), replace its DETECTED length with the CALIBRATED one while
/// keeping the DIRECTION Vision/LiDAR detected it pointing in — this preserves the actual pose
/// shape (arms raised, legs bent, etc.) and only fixes the segment's size. Bones with no calibrated
/// reference (hip width, shoulder width, neck/head) are carried forward with their exact detected
/// offset, just re-anchored to wherever their (possibly now-corrected) parent joint ended up, so
/// the skeleton stays fully connected.
///
/// `.root` itself is never moved — it's the trusted anchor (wherever LiDAR/Vision actually placed
/// the climber relative to the wall), only the shape hanging off of it is corrected.
///
/// If Step 2's calibration itself was captured badly (climber not fully/squarely in frame, wrong
/// pose, occlusion), this will faithfully reproduce that bad measurement — there's no way for a
/// per-frame correction to know the SOURCE measurement was wrong. If a generated skeleton still
/// looks proportioned wrong after this, recapturing Step 2 calibration is the right fix, not this
/// code.
enum CalibrationScaleCorrection {
    /// A bone's implied correction is only trusted within this range — outside it, the DETECTED
    /// bone is more likely a degenerate/wrong detection than the calibration being that far off,
    /// so it's left alone (carried forward as detected) rather than "corrected" into something
    /// worse. Wider than a whole-body height tolerance would be, since individual limbs vary more.
    private static let minTrustedScale: Float = 0.4
    private static let maxTrustedScale: Float = 2.5
    /// Below this detected length (meters), a bone is treated as degenerate/effectively
    /// undetected — its direction is meaningless at this scale, so it's left untouched rather than
    /// normalized (which would amplify noise into an arbitrary direction).
    private static let minDetectableBoneLength: Float = 0.02

    /// Returns `worldPositions` with every calibrated bone corrected to the climber's measured
    /// length, or completely unchanged if `calibratedSegments` is nil (Step 2 was skipped for this
    /// session).
    static func retargeted(
        _ worldPositions: [BodyJointName: SIMD3<Float>],
        toMatch calibratedSegments: SegmentLengths?
    ) -> [BodyJointName: SIMD3<Float>] {
        guard let calibratedSegments else { return worldPositions }
        var positions = worldPositions

        // Torso is a special case: only the straight-line root-to-centerShoulder distance is
        // calibrated (`torsoLength`) — see `CalibrationEngine.deriveSegments` — but the skeleton
        // has TWO bones in between (root->spine, spine->centerShoulder), neither individually
        // calibrated. Rather than skip torso correction entirely, distribute the calibrated total
        // across both sub-bones in the SAME proportion Vision detected between them — an
        // approximation (it trusts the two-segment path's proportions even though its total length
        // wasn't trustworthy), but strictly better than leaving an obviously-wrong total torso
        // length uncorrected.
        let torsoScale = trustedScale(
            calibratedLength: calibratedSegments.torsoLength,
            detectedLength: detectedPathLength(.root, .spine, .centerShoulder, in: worldPositions)
        )

        // `skeletonBones` is already listed in parent-before-child order for every branch of the
        // tree (root -> spine -> centerShoulder -> ... etc. — see its declaration), so a single
        // pass in that order is enough: every bone's `from` joint has already been finalized
        // (corrected or carried forward) by the time it's this bone's turn.
        for bone in skeletonBones {
            guard let parent = positions[bone.from], let originalChild = worldPositions[bone.to] else { continue }
            let originalParent = worldPositions[bone.from] ?? parent
            let detectedOffset = originalChild - originalParent
            let detectedLength = simd_length(detectedOffset)
            guard detectedLength > minDetectableBoneLength else { continue }

            let targetLength: Float?
            switch (bone.from, bone.to) {
            case (.leftShoulder, .leftElbow), (.rightShoulder, .rightElbow):
                targetLength = trustedLength(calibratedSegments.upperArmLength, detectedLength)
            case (.leftElbow, .leftWrist), (.rightElbow, .rightWrist):
                targetLength = trustedLength(calibratedSegments.forearmLength, detectedLength)
            case (.leftHip, .leftKnee), (.rightHip, .rightKnee):
                targetLength = trustedLength(calibratedSegments.thighLength, detectedLength)
            case (.leftKnee, .leftAnkle), (.rightKnee, .rightAnkle):
                targetLength = trustedLength(calibratedSegments.shinLength, detectedLength)
            case (.root, .spine), (.spine, .centerShoulder):
                targetLength = torsoScale.map { detectedLength * $0 }
            default:
                // No calibrated reference for this bone (hip width, shoulder width, neck/head) —
                // fall through to carrying the exact detected offset forward below.
                targetLength = nil
            }

            if let targetLength {
                positions[bone.to] = parent + (detectedOffset / detectedLength) * targetLength
            } else {
                positions[bone.to] = parent + detectedOffset
            }
        }
        return positions
    }

    /// Sums the straight-line distances between consecutive joints in `joints` using their
    /// ORIGINAL detected positions — nil if any joint along the path is missing.
    private static func detectedPathLength(_ joints: BodyJointName..., in positions: [BodyJointName: SIMD3<Float>]) -> Float? {
        var total: Float = 0
        for i in 0..<(joints.count - 1) {
            guard let a = positions[joints[i]], let b = positions[joints[i + 1]] else { return nil }
            total += simd_distance(a, b)
        }
        return total
    }

    /// Returns the calibrated length itself if it and the resulting scale factor both look
    /// trustworthy, else nil — meaning "don't correct this bone, carry the detected one forward."
    private static func trustedLength(_ calibratedLength: Float, _ detectedLength: Float) -> Float? {
        guard calibratedLength > 0 else { return nil }
        let scale = calibratedLength / detectedLength
        guard scale > minTrustedScale, scale < maxTrustedScale else {
            DebugLog.reconstruction.error("Calibration bone correction skipped — implied scale \(scale, privacy: .public) outside trusted range")
            return nil
        }
        return calibratedLength
    }

    /// Torso variant of `trustedLength` — returns a trusted SCALE FACTOR (not a length, since the
    /// calibrated total needs to be distributed across two sub-bones) for the two torso sub-bones,
    /// or nil if untrustworthy/unmeasurable.
    private static func trustedScale(calibratedLength: Float, detectedLength: Float?) -> Float? {
        guard calibratedLength > 0, let detectedLength, detectedLength > minDetectableBoneLength * 2 else { return nil }
        let scale = calibratedLength / detectedLength
        guard scale > minTrustedScale, scale < maxTrustedScale else {
            DebugLog.reconstruction.error("Calibration torso correction skipped — implied scale \(scale, privacy: .public) outside trusted range")
            return nil
        }
        return scale
    }
}

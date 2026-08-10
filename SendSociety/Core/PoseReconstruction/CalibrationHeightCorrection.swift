import Foundation
import simd

/// Decides whether/how a climber's entered height should adjust their measured `CalibrationResult`
/// — pulled out of `CalibrationView` since this is a pure calculation over already-captured data,
/// not view logic. Deliberately NOT a blanket "always trust the entered number" — see the two
/// branches below for why the right answer depends on how the capture was grounded.
enum CalibrationHeightCorrection {
    /// A starting point, not tuned against real measurements.
    private static let groundedDisagreementTolerance: Float = 0.04

    /// - `.ungrounded` (no real LiDAR depth for this capture — Vision's own monocular depth/scale
    ///   estimate had to be used instead): that estimate has a genuinely AMBIGUOUS absolute scale —
    ///   this is a well-known limitation of single-camera 3D pose estimation, not a small bias. A
    ///   known true height is the standard fix for exactly this problem, so it's legitimate (and an
    ///   improvement) to rescale every measured segment length by `entered / measured` here.
    /// - `.grounded` (the normal case — every joint placed using real LiDAR depth): the height
    ///   number here already comes from an actual physical distance measurement, not an ambiguous
    ///   scale estimate. Any remaining error is almost certainly landmark-placement precision —
    ///   exactly where Vision decides "top of head" or "ankle" sits, which can be a few cm off the
    ///   literal top-of-head/floor-contact point — NOT a uniform scale error. Rescaling every OTHER
    ///   segment (arm/leg/torso lengths, which are likely already accurate) by `entered / measured`
    ///   to chase that fix would inject a new proportional error into numbers that didn't need
    ///   correcting — net LESS accurate overall. So this case only cross-checks and warns if the
    ///   two disagree by more than a rough tolerance; it never rescales.
    /// - `nil` grounding mode (shouldn't normally happen — only ever called with a real, already
    ///   fully-captured `CalibrationResult`) is treated the same as `.grounded`: cross-check only,
    ///   never rescale.
    static func apply(
        to result: CalibrationResult,
        enteredHeightMeters: Float?,
        groundingMode: CalibrationFrameProcessor.GroundingMode?
    ) -> (result: CalibrationResult, heightNote: String?) {
        guard let enteredHeightMeters, result.segments.height > 0 else {
            return (result, nil)
        }
        let measured = result.segments.height
        let percentDiff = abs(measured - enteredHeightMeters) / enteredHeightMeters

        switch groundingMode {
        case .ungrounded:
            let scale = enteredHeightMeters / measured
            var corrected = result
            corrected.segments.height = enteredHeightMeters
            corrected.segments.armSpan *= scale
            corrected.segments.upperArmLength *= scale
            corrected.segments.forearmLength *= scale
            corrected.segments.thighLength *= scale
            corrected.segments.shinLength *= scale
            corrected.segments.torsoLength *= scale
            corrected.segments.handSpan *= scale
            var scaledJoints: [BodyJointName: SIMD3<Float>] = [:]
            for (joint, position) in result.averagedJoints {
                scaledJoints[joint] = position * scale
            }
            corrected.averagedJoints = scaledJoints
            corrected.enteredHeightMeters = enteredHeightMeters
            let note = String(format: "No LiDAR depth was available for this capture, so the entered height (%.0fcm) was used to scale the whole measurement.", enteredHeightMeters * 100)
            return (corrected, note)

        case .grounded, .none:
            var withEntered = result
            withEntered.enteredHeightMeters = enteredHeightMeters
            guard percentDiff > groundedDisagreementTolerance else { return (withEntered, nil) }
            let note = String(
                format: "Entered height (%.0fcm) differs from the measured height (%.0fcm) by %.0f%% — this usually means the climber wasn't fully/squarely in frame, or was at an angle. The measured value is being used, since it comes from real depth data; consider recapturing if this gap seems too large.",
                enteredHeightMeters * 100, measured * 100, percentDiff * 100
            )
            return (withEntered, note)
        }
    }
}

import Foundation
import simd

/// The 4 linear steps of the MVP capture pipeline. Navigation is strictly forward for this
/// phase — no re-ordering, no skipping.
enum AppStep: Int, CaseIterable {
    case wallScan = 0
    case calibration
    case recording
    case reconstruction

    var title: String {
        switch self {
        case .wallScan: return "Scan the Wall"
        case .calibration: return "Calibrate Climber"
        case .recording: return "Record the Climb"
        case .reconstruction: return "3D Reconstruction"
        }
    }
}

/// Simplified tracking-quality bucket surfaced to the coach as a real-time on-screen cue.
enum TrackingQuality: Equatable {
    case normal
    case limited(String)
    case notAvailable
    case relocalizing

    /// nil when tracking is fine and no cue should be shown.
    var message: String? {
        switch self {
        case .normal: return nil
        case .limited(let reason): return reason
        case .notAvailable: return "Tracking lost — point the camera at the wall"
        case .relocalizing: return "Relocalizing — move slowly"
        }
    }
}

/// Our own mirror of VNHumanBodyPose3DObservation.JointName (17 joints), kept independent of
/// the Vision type so non-Vision files (rendering, models) don't need to import Vision.
enum BodyJointName: String, CaseIterable, Hashable {
    case centerHead, topHead
    case centerShoulder, leftShoulder, rightShoulder
    case spine, root
    case leftHip, rightHip
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
}

/// Real-world segment lengths computed during Step 2 calibration, in meters.
struct SegmentLengths {
    var height: Float = 0
    var armSpan: Float = 0
    var upperArmLength: Float = 0      // shoulder -> elbow, averaged L/R
    var forearmLength: Float = 0       // elbow -> wrist, averaged L/R
    var thighLength: Float = 0         // hip -> knee, averaged L/R
    var shinLength: Float = 0          // knee -> ankle, averaged L/R
    var torsoLength: Float = 0         // centerShoulder -> root
    var handSpan: Float = 0            // rough placeholder — the 17-joint set has no finger joints
}

/// Result of Step 2 calibration: averaged joints + derived segment lengths. In-memory only for
/// this MVP — no cross-session persistence.
struct CalibrationResult {
    var segments: SegmentLengths
    var frameCount: Int
    var averagedJoints: [BodyJointName: SIMD3<Float>]
    var capturedAt: Date
}

/// A single skeletal edge for rendering. Hard-coded rather than relying on Vision's
/// `parentJoint` property, so skeleton rendering doesn't depend on an unverified API shape.
struct SkeletonBone {
    let from: BodyJointName
    let to: BodyJointName
}

let skeletonBones: [SkeletonBone] = [
    .init(from: .root, to: .spine),
    .init(from: .spine, to: .centerShoulder),
    .init(from: .centerShoulder, to: .leftShoulder),
    .init(from: .centerShoulder, to: .rightShoulder),
    .init(from: .leftShoulder, to: .leftElbow),
    .init(from: .leftElbow, to: .leftWrist),
    .init(from: .rightShoulder, to: .rightElbow),
    .init(from: .rightElbow, to: .rightWrist),
    .init(from: .centerShoulder, to: .centerHead),
    .init(from: .centerHead, to: .topHead),
    .init(from: .root, to: .leftHip),
    .init(from: .root, to: .rightHip),
    .init(from: .leftHip, to: .leftKnee),
    .init(from: .leftKnee, to: .leftAnkle),
    .init(from: .rightHip, to: .rightKnee),
    .init(from: .rightKnee, to: .rightAnkle),
]

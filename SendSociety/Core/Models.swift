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

/// Mirror of VNHumanHandPoseObservation.JointName (21 joints per hand), independent of Vision for
/// the same reason as `BodyJointName`. Vision has NO 3D hand pose API — these come from the
/// 2D-only hand request and get their depth from real LiDAR data (see
/// `BodyPose3DExtractor.detectHands`), not from Vision itself.
enum HandJointName: String, CaseIterable, Hashable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

struct HandBone {
    let from: HandJointName
    let to: HandJointName
}

let handBones: [HandBone] = [
    .init(from: .wrist, to: .thumbCMC), .init(from: .thumbCMC, to: .thumbMP), .init(from: .thumbMP, to: .thumbIP), .init(from: .thumbIP, to: .thumbTip),
    .init(from: .wrist, to: .indexMCP), .init(from: .indexMCP, to: .indexPIP), .init(from: .indexPIP, to: .indexDIP), .init(from: .indexDIP, to: .indexTip),
    .init(from: .wrist, to: .middleMCP), .init(from: .middleMCP, to: .middlePIP), .init(from: .middlePIP, to: .middleDIP), .init(from: .middleDIP, to: .middleTip),
    .init(from: .wrist, to: .ringMCP), .init(from: .ringMCP, to: .ringPIP), .init(from: .ringPIP, to: .ringDIP), .init(from: .ringDIP, to: .ringTip),
    .init(from: .wrist, to: .littleMCP), .init(from: .littleMCP, to: .littlePIP), .init(from: .littlePIP, to: .littleDIP), .init(from: .littleDIP, to: .littleTip),
]

/// Fixed vocabulary of hand grip types the coach can be shown, in place of precise (and, per
/// LiDAR's ~1-3cm real-world accuracy vs. finger-scale detail, unreliable) raw finger
/// reconstruction — see `GripClassifier`'s doc comment for the full reasoning.
enum HandGripType: String, CaseIterable {
    case jug, openHand, halfCrimp, fullCrimp, pinch, pocket, sloper, undercling, gaston

    var displayName: String {
        switch self {
        case .jug: return "Jug"
        case .openHand: return "Open hand"
        case .halfCrimp: return "Half-crimp"
        case .fullCrimp: return "Full-crimp"
        case .pinch: return "Pinch"
        case .pocket: return "Pocket"
        case .sloper: return "Sloper"
        case .undercling: return "Undercling"
        case .gaston: return "Gaston"
        }
    }
}

/// Fixed vocabulary of foot placement types — same classify-then-snap-to-preset approach as
/// `HandGripType`.
enum FootPlacementType: String, CaseIterable {
    case insideEdge, outsideEdge, toe, heelHook, smear

    var displayName: String {
        switch self {
        case .insideEdge: return "Inside edge"
        case .outsideEdge: return "Outside edge"
        case .toe: return "Toe"
        case .heelHook: return "Heel hook"
        case .smear: return "Smear"
        }
    }
}

/// Result of `GripClassifier.classifyHand` — a best-guess category plus an honest confidence
/// score, NOT precise geometry. `confidence` is a heuristic proxy for "how much geometric signal
/// was available and how clearly it pointed at this category," not a calibrated probability —
/// see `GripClassifier` for the full caveat.
struct GripClassification {
    let type: HandGripType
    let confidence: Float
}

/// Result of `GripClassifier.classifyFoot` — same caveats as `GripClassification`, but built from
/// even less signal (skeleton geometry only, no foot/toe joints exist in Vision's output at all).
struct FootClassification {
    let type: FootPlacementType
    let confidence: Float
}

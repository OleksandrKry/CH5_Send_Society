import CoreGraphics
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
enum BodyJointName: String, CaseIterable, Hashable, Codable {
    case centerHead, topHead
    case centerShoulder, leftShoulder, rightShoulder
    case spine, root
    case leftHip, rightHip
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
}

/// Real-world segment lengths computed during Step 2 calibration, in meters. `Codable` (trivially
/// — every field is a plain `Float`) so a `CalibrationResult` can be saved with its owning
/// `RecordingSession`.
struct SegmentLengths: Codable {
    var height: Float = 0
    var armSpan: Float = 0
    var upperArmLength: Float = 0      // shoulder -> elbow, averaged L/R
    var forearmLength: Float = 0       // elbow -> wrist, averaged L/R
    var thighLength: Float = 0         // hip -> knee, averaged L/R
    var shinLength: Float = 0          // knee -> ankle, averaged L/R
    var torsoLength: Float = 0         // centerShoulder -> root
    var handSpan: Float = 0            // rough placeholder — the 17-joint set has no finger joints
}

/// Result of Step 2 calibration: averaged joints + derived segment lengths. Now persisted as part
/// of a `RecordingSession` (see `Core/Persistence`).
struct CalibrationResult {
    var segments: SegmentLengths
    var frameCount: Int
    var averagedJoints: [BodyJointName: SIMD3<Float>]
    var capturedAt: Date
    /// The climber's self-reported height, if they entered one — see
    /// `CalibrationView.finalizedResult` for how (and whether) this is actually used to adjust
    /// `segments`. Stored here mainly so the confirmation UI can show "measured vs. entered"
    /// without needing to thread a second value alongside this struct everywhere it's passed.
    var enteredHeightMeters: Float? = nil
}

/// Manual `Codable` — `averagedJoints`'s `SIMD3<Float>` values need `Core/Persistence/
/// CodableSIMD.swift`'s conformance, which Swift's automatic synthesis failed to recognize across
/// files (see `WallScanArchive.Metadata`'s doc comment for the full story). Writing this by hand
/// sidesteps that.
extension CalibrationResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case segments, frameCount, averagedJoints, capturedAt, enteredHeightMeters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segments = try container.decode(SegmentLengths.self, forKey: .segments)
        frameCount = try container.decode(Int.self, forKey: .frameCount)
        averagedJoints = try container.decode([BodyJointName: SIMD3<Float>].self, forKey: .averagedJoints)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        enteredHeightMeters = try container.decodeIfPresent(Float.self, forKey: .enteredHeightMeters)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segments, forKey: .segments)
        try container.encode(frameCount, forKey: .frameCount)
        try container.encode(averagedJoints, forKey: .averagedJoints)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encodeIfPresent(enteredHeightMeters, forKey: .enteredHeightMeters)
    }
}

/// A single skeletal edge for rendering. Hard-coded rather than relying on Vision's
/// `parentJoint` property, so skeleton rendering doesn't depend on an unverified API shape.
/// Hashable so `SkeletonPoseEditor`/`ReconstructionEntityBuilder` can track sets of bones (e.g.
/// which ones are highlighted during a drag) without a separate string-key scheme.
struct SkeletonBone: Hashable {
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
enum HandJointName: String, CaseIterable, Hashable, Codable {
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
enum HandGripType: String, CaseIterable, Codable {
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
enum FootPlacementType: String, CaseIterable, Codable {
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
struct GripClassification: Codable {
    let type: HandGripType
    let confidence: Float
}

/// Result of `GripClassifier.classifyFoot` — same caveats as `GripClassification`, but built from
/// even less signal (skeleton geometry only, no foot/toe joints exist in Vision's output at all).
struct FootClassification: Codable {
    let type: FootPlacementType
    let confidence: Float
}

// MARK: - 2D annotation markup (Step 4's "draw on the paused view" feature)

/// Which drawing tool made an `AnnotationStroke` — see that type's doc comment for the shape of
/// `points` each one implies. Declared here (AppCore), not in the SwiftUI file that draws it
/// (`Features/Reconstruction/AnnotationOverlay.swift`), because `AnnotationStroke` is a persisted
/// model type: `Core/Persistence/RecordingSession.swift` stores arrays of it directly, and a
/// persistence file should never need to import a feature's UI file just to compile its own saved
/// data. `AnnotationOverlay`/`AnnotationToolbar`/`AnnotationState` (the actual drawing surface,
/// toolbar, and `ObservableObject` state) stay in Features/Reconstruction — those genuinely are UI.
enum AnnotationTool: String, CaseIterable, Codable {
    case pen, line, angle

    var systemImage: String {
        switch self {
        case .pen: return "pencil"
        case .line: return "line.diagonal"
        case .angle: return "angle"
        }
    }

    var label: String {
        switch self {
        case .pen: return "Pen"
        case .line: return "Line"
        case .angle: return "Angle"
        }
    }
}

/// One piece of 2D screen-space markup drawn on a paused Step 4 view — pen (freehand), line
/// (straight segment), or angle (two segments sharing a vertex, rendered with the angle between
/// them labeled). Persisted as part of a `RecordingSession`'s saved video annotations/3D
/// reconstructions (see `VideoAnnotationEntry`/`ReconstructionEntry` in `Core/Persistence`).
struct AnnotationStroke: Identifiable, Codable, Equatable {
    var id = UUID()
    var tool: AnnotationTool
    /// pen: every sampled point along the drag. line: [start, end]. angle: [vertex, endA, endB].
    var points: [CGPoint]
}

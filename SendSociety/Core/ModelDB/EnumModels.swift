import CoreGraphics
import Foundation
import simd


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

// MARK: - 2D annotation markup (Step 4's "draw on the paused view" feature)

enum AnnotationTool: String, CaseIterable, Codable {
    case pen, line, angle, circle, arrow, text

    var systemImage: String {
        switch self {
        case .pen: return "pencil"
        case .line: return "line.diagonal"
        case .angle: return "angle"
        case .circle: return "circle"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        }
    }
}

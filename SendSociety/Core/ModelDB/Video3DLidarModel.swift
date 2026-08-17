//
//  Video3DResult.swift
//  SendSociety
//
//  Created by Christofer Theodore on 15/08/26.
//
import ARKit
import simd

struct Video3DLidar {
    /// The timestamp this result is actually for — may differ slightly from the originally
    /// requested moment if an existing saved entry nearby was loaded instead of that exact spot.
    let timestampSeconds: Double
    /// The stable "auto-detected baseline" positions — what every later joint-edit/annotation
    /// save writes on top of, never the coach's edits themselves.
    let baseWorldPositions: [BodyJointName: SIMD3<Float>]
    let originalAppleVisionJoints: [BodyJointName: SIMD3<Float>]?
    let modifiedAppleVisionJoints: [BodyJointName: SIMD3<Float>]?
    let initialAnnotationStrokes: [AnnotationStrokeModel]
    let appleVisionSkeleton: AppleVisionSkeleton?
    let cameraTransform: simd_float4x4?
    let depthContext: AppleVisionSkeletonExtractor.DepthGroundingContext?
    let poseError: String?
    /// True if this came from an already-saved reconstruction (Vision never ran); false if this
    /// is a brand-new detection.
    let wasLoadedFromSavedEntry: Bool
}

struct Video3DLidarInput {
    let videoURL: URL
    let frameStore: ARFrameStore
    let timestampSeconds: TimeInterval
    let clipStartTimestamp: TimeInterval
}

struct Video3DLidarSkeleton: Identifiable {
    var id: UUID = UUID()
    var timestampSeconds: Double
    var originalAppleVisionJoints: [BodyJointName: SIMD3<Float>]
    var modifiedAppleVisionJoints: [BodyJointName: SIMD3<Float>]?
    var annotationStrokes: [AnnotationStrokeModel] = []
    var isApproximate: Bool = false
}

extension Video3DLidarSkeleton: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, timestampSeconds, originalAppleVisionJoints, modifiedAppleVisionJoints
        case annotationStrokes, isApproximate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestampSeconds = try container.decode(Double.self, forKey: .timestampSeconds)
        originalAppleVisionJoints = try container.decode([BodyJointName: SIMD3<Float>].self, forKey: .originalAppleVisionJoints)
        modifiedAppleVisionJoints = try container.decodeIfPresent([BodyJointName: SIMD3<Float>].self, forKey: .modifiedAppleVisionJoints)
        annotationStrokes = try container.decodeIfPresent([AnnotationStrokeModel].self, forKey: .annotationStrokes) ?? []
        isApproximate = try container.decodeIfPresent(Bool.self, forKey: .isApproximate) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestampSeconds, forKey: .timestampSeconds)
        try container.encode(originalAppleVisionJoints, forKey: .originalAppleVisionJoints)
        try container.encodeIfPresent(modifiedAppleVisionJoints, forKey: .modifiedAppleVisionJoints)
        try container.encode(annotationStrokes, forKey: .annotationStrokes)
        try container.encode(isApproximate, forKey: .isApproximate)
    }
}

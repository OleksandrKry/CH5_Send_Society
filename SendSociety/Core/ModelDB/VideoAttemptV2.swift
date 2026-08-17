//
//  VideoAttemptV2.swift
//  SendSociety
//
//  Created by Christofer Theodore on 14/08/26.
//

import Foundation
import SwiftData
import simd

/// One recorded clip within a RecordingSessionV2 — everything that used to live directly on
/// RecordingSession and is genuinely PER-VIDEO, not per-wall-scan.
struct VideoAttemptV2: Identifiable {
    var id: UUID = UUID()
    /// When THIS clip was recorded — distinct from the session's createdAt (when the wall scan
    /// started). Will drive the order/timestamp shown in the thumbnail row later.
    var createdAt: Date = Date()

    var videoFileName: String
    var videoDurationSeconds: Double
    var recordingDeviceOrientationRawValue: Int = 0
    var clipStartTimestamp: TimeInterval = 0   // <- new

    var videoAnnotations: [VideoAnnotationEntry] = []
    var video3DLidarSkeletons: [Video3DLidarSkeleton] = []
    
    var routeGrade: RouteGrade = .v0
    var climberID: UUID?
    
    /// Upserts a video annotation for timestampSeconds, replacing whatever was previously saved
    /// within mergeToleranceSeconds of it — so scrubbing to a slightly different position on a
    /// later visit updates the existing markup instead of piling up near-duplicate entries.
    mutating func setVideoAnnotation(timestampSeconds: Double, strokes: [AnnotationStrokeModel], mergeToleranceSeconds: Double = 1.0) {
        if let index = videoAnnotations.firstIndex(where: { abs($0.timestampSeconds - timestampSeconds) <= mergeToleranceSeconds }) {
            if strokes.isEmpty {
                videoAnnotations.remove(at: index)
            } else {
                videoAnnotations[index].strokes = strokes
                videoAnnotations[index].timestampSeconds = timestampSeconds
            }
        } else if !strokes.isEmpty {
            videoAnnotations.append(VideoAnnotationEntry(timestampSeconds: timestampSeconds, strokes: strokes))
        }
    }

    /// Upserts a reconstruction for entry.timestampSeconds — same nearest-timestamp merge idea
    /// as setVideoAnnotation.
    mutating func upsertSkeleton(_ entry: Video3DLidarSkeleton, mergeToleranceSeconds: Double = 0.3) {
        if let index = video3DLidarSkeletons.firstIndex(where: { abs($0.timestampSeconds - entry.timestampSeconds) <= mergeToleranceSeconds }) {
            video3DLidarSkeletons[index] = entry
        } else {
            video3DLidarSkeletons.append(entry)
        }
    }

    /// Deletes one saved reconstruction by id — lets a coach clear out a bad test run.
    mutating func removeSkeleton(id: UUID) {
        video3DLidarSkeletons.removeAll { $0.id == id }
    }
}

extension VideoAttemptV2: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, videoFileName, videoDurationSeconds
        case recordingDeviceOrientationRawValue, videoAnnotations, video3DLidarSkeletons
        case clipStartTimestamp
        case routeGrade, climberID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        videoFileName = try container.decode(String.self, forKey: .videoFileName)
        videoDurationSeconds = try container.decode(Double.self, forKey: .videoDurationSeconds)
        recordingDeviceOrientationRawValue = try container.decodeIfPresent(Int.self, forKey: .recordingDeviceOrientationRawValue) ?? 0
        videoAnnotations = try container.decodeIfPresent([VideoAnnotationEntry].self, forKey: .videoAnnotations) ?? []
        video3DLidarSkeletons = try container.decodeIfPresent([Video3DLidarSkeleton].self, forKey: .video3DLidarSkeletons) ?? []
        clipStartTimestamp = try container.decodeIfPresent(Double.self, forKey: .clipStartTimestamp) ?? 0
        routeGrade = try container.decodeIfPresent(RouteGrade.self, forKey: .routeGrade) ?? .v0
        climberID = try container.decodeIfPresent(UUID.self, forKey: .climberID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(videoFileName, forKey: .videoFileName)
        try container.encode(videoDurationSeconds, forKey: .videoDurationSeconds)
        try container.encode(recordingDeviceOrientationRawValue, forKey: .recordingDeviceOrientationRawValue)
        try container.encode(videoAnnotations, forKey: .videoAnnotations)
        try container.encode(video3DLidarSkeletons, forKey: .video3DLidarSkeletons)
        try container.encode(clipStartTimestamp, forKey: .clipStartTimestamp)
        try container.encode(routeGrade, forKey: .routeGrade)
        try container.encodeIfPresent(climberID, forKey: .climberID)
    }
}



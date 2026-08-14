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
struct VideoAttemptV2: Identifiable, Codable {
    var id: UUID = UUID()
    /// When THIS clip was recorded — distinct from the session's createdAt (when the wall scan
    /// started). Will drive the order/timestamp shown in the thumbnail row later.
    var createdAt: Date = Date()

    var videoFileName: String
    var videoDurationSeconds: Double
    var recordingDeviceOrientationRawValue: Int = 0

    var videoAnnotations: [VideoAnnotationEntry] = []
    var reconstructions: [ReconstructionEntry] = []
    
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
    mutating func upsertReconstruction(_ entry: ReconstructionEntry, mergeToleranceSeconds: Double = 0.3) {
        if let index = reconstructions.firstIndex(where: { abs($0.timestampSeconds - entry.timestampSeconds) <= mergeToleranceSeconds }) {
            reconstructions[index] = entry
        } else {
            reconstructions.append(entry)
        }
    }

    /// Deletes one saved reconstruction by id — lets a coach clear out a bad test run.
    mutating func removeReconstruction(id: UUID) {
        reconstructions.removeAll { $0.id == id }
    }
}



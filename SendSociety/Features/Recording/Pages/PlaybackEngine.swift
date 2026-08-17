import Foundation

/// PlaybackEngine is the "brain" behind the video review screen — it does NOT import SwiftUI and
/// does NOT know about colors, fonts, buttons, or layout. It answers two questions, purely from
/// the data it's given:
///
///   1. "What drawing (if any) belongs to this exact moment in the video?"
///   2. "What are ALL the saved moments, so I can put a marker on the scrubber for each one?"
///
/// Saving is NOT this engine's job — `PlaybackLayerV2` owns that, since only it has access to
/// `RecordingSessionV2`/`SessionStoreV2`. This engine only ever reads whatever snapshot of
/// annotations/reconstructions it's constructed with.
final class PlaybackEngine {
    /// How close (in seconds) the video's current position needs to be to a saved drawing
    /// before that drawing counts as "the one showing right now."
    static let annotationMatchWindowSeconds: Double = 1.0

    /// How close (in seconds) a saved drawing needs to be to a saved 3D pose before the two are
    /// combined into ONE marker on the scrubber, instead of showing as two separate dots.
    static let markerMergeWindowSeconds: Double = 0.5

    private let videoAnnotations: [VideoAnnotationEntry]
    private let reconstructions: [Video3DLidarSkeleton]

    init(videoAnnotations: [VideoAnnotationEntry], reconstructions: [Video3DLidarSkeleton]) {
        self.videoAnnotations = videoAnnotations
        self.reconstructions = reconstructions
    }

    func findDrawing(nearVideoTime videoTimeInSeconds: Double) -> [AnnotationStrokeModel] {
        let closestMatch = videoAnnotations.first {
            abs($0.timestampSeconds - videoTimeInSeconds) <= Self.annotationMatchWindowSeconds
        }
        return closestMatch?.strokes ?? []
    }

    func getVideoMarkerList() -> [VideoMarkerModel] {
        var moments: [VideoMarkerModel] = reconstructions.map { pose in
            VideoMarkerModel(
                id: pose.id,
                videoTimeInSeconds: pose.timestampSeconds,
                hasDrawing: false,
                has3DPose: true,
                is3DPoseApproximate: pose.isApproximate
            )
        }

        for drawing in videoAnnotations {
            if let matchIndex = moments.firstIndex(where: { abs($0.videoTimeInSeconds - drawing.timestampSeconds) <= Self.markerMergeWindowSeconds }) {
                let existingMarker = moments[matchIndex]
                moments[matchIndex] = VideoMarkerModel(
                    id: existingMarker.id,
                    videoTimeInSeconds: existingMarker.videoTimeInSeconds,
                    hasDrawing: true,
                    has3DPose: existingMarker.has3DPose,
                    is3DPoseApproximate: existingMarker.is3DPoseApproximate
                )
            } else {
                moments.append(VideoMarkerModel(
                    id: drawing.id,
                    videoTimeInSeconds: drawing.timestampSeconds,
                    hasDrawing: true,
                    has3DPose: false,
                    is3DPoseApproximate: false
                ))
            }
        }

        return moments.sorted { $0.videoTimeInSeconds < $1.videoTimeInSeconds }
    }
}

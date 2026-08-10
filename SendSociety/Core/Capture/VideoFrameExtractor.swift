import AVFoundation
import CoreGraphics

/// Pulls a single frame out of a saved video file at an arbitrary timestamp — used by
/// `SessionReviewView`'s "Estimate 3D" action, which needs to run Vision body-pose detection on a
/// moment from a saved recording that was never grounded in real LiDAR depth (see
/// `ReconstructionEntry.isApproximate`'s doc comment for why that's a real limitation, and what
/// this trades away vs. a live-generated reconstruction).
enum VideoFrameExtractor {
    /// Returns the frame nearest `seconds` into the video at `url`, in the video's RAW native
    /// pixel layout — deliberately `appliesPreferredTrackTransform = false` (the default), NOT
    /// true. `VideoRecorder` writes frames straight from ARKit's raw, always-landscape
    /// `capturedImage` buffer and tags the file with a separate rotation `transform` for players to
    /// apply at DISPLAY time (see `VideoRecorder.videoTransform(for:)`); leaving that transform
    /// unapplied here means the returned image is in the exact same raw layout `ARFrame
    /// .capturedImage` always was, which is what `BodyPose3DExtractor.detect(inVideoFrame
    /// :deviceOrientation:)` expects (matching `detect(in:deviceOrientation:)`'s handling of live
    /// frames) — this project's earlier attempt at applying the preferred transform here and
    /// passing a fixed `.up` orientation to Vision is exactly what caused re-generated postures to
    /// come out facing the wrong direction; see that function's doc comment for the full story.
    static func extractFrame(from url: URL, atSeconds seconds: Double) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = false
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        do {
            return try generator.copyCGImage(at: time, actualTime: nil)
        } catch {
            DebugLog.reconstruction.error("VideoFrameExtractor: failed to extract frame at \(seconds, privacy: .public)s: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

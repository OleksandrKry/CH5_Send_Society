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

    /// Extracts `count` evenly-spaced thumbnails across `range` seconds of the video at `url` —
    /// backs `PreciseScrubBar`'s visual scrubbing reference. `range` is a narrow (few-second) window
    /// around the current playhead, not the whole clip: a dense set of frames over a short span gets
    /// a coach precise enough visual feedback to land on one exact moment. Unlike `extractFrame`
    /// above, this applies the preferred track transform (`= true`): these thumbnails are for a
    /// coach to look at, so they need to match what `SilentVideoPlayer` actually displays (which
    /// auto-applies that same transform), not Vision's raw-buffer expectations.
    ///
    /// Uses `generateCGImagesAsynchronously`, NOT a loop of `copyCGImage` calls: for a batch of
    /// nearby timestamps (exactly this case — a couple of seconds of footage) the batch API reuses
    /// decode state between adjacent frames instead of re-seeking from scratch for each one, which is
    /// what made the previous `copyCGImage`-loop version of this function feel laggy the first time
    /// `PreciseScrubBar` appeared. `copyCGImage` is also blocking, which is why that version needed a
    /// `Task.detached` wrapper; `generateCGImagesAsynchronously` schedules its own background work
    /// and calls back via a completion handler, so this function just bridges that into `async`.
    static func extractThumbnailStrip(from url: URL, range: ClosedRange<Double>, count: Int) async -> [(time: Double, image: CGImage)] {
        guard range.upperBound.isFinite, range.upperBound > range.lowerBound, count > 0 else { return [] }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 200, height: 200)

        let span = range.upperBound - range.lowerBound
        let seconds = (0..<count).map { range.lowerBound + span * Double($0) / Double(max(count - 1, 1)) }
        let times = seconds.map { CMTime(seconds: $0, preferredTimescale: 600) }
        let requestedValues = times.map { NSValue(time: $0) }

        return await withCheckedContinuation { (continuation: CheckedContinuation<[(time: Double, image: CGImage)], Never>) in
            let lock = NSLock()
            var imagesByTime: [CMTime: CGImage] = [:]
            var remaining = requestedValues.count

            generator.generateCGImagesAsynchronously(forTimes: requestedValues) { requestedTime, cgImage, _, status, _ in
                lock.lock()
                if status == .succeeded, let cgImage {
                    imagesByTime[requestedTime] = cgImage
                }
                remaining -= 1
                let isDone = remaining == 0
                lock.unlock()

                guard isDone else { return }
                let ordered: [(time: Double, image: CGImage)] = zip(seconds, times).compactMap { second, time in
                    imagesByTime[time].map { (second, $0) }
                }
                continuation.resume(returning: ordered)
            }
        }
    }
}

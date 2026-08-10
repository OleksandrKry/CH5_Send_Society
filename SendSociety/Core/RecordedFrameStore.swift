import ARKit
import Foundation
import UIKit

/// One ARKit frame's world-alignment data, captured during Step 3 recording.
struct RecordedFrameData {
    let timestamp: TimeInterval
    let cameraTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageResolution: CGSize
    let depthMap: CVPixelBuffer?
    let confidenceMap: CVPixelBuffer?
    let capturedImage: CVPixelBuffer
    /// Device orientation AT THE MOMENT this frame was recorded — NOT something to re-read from
    /// `UIDevice.current.orientation` later. Step 4 processes this frame potentially minutes
    /// after it was captured (after the coach finishes recording, scrubs the video, and taps
    /// Generate), by which point the device may genuinely be held differently (set down, handed
    /// off, propped on something). `BodyPose3DExtractor.detect(in:)` needs the orientation that
    /// was actually true WHEN THE PIXELS WERE CAPTURED to correctly interpret them, and
    /// `DepthGroundingContext.deviceOrientation` (below) needs to match it exactly — a mismatch
    /// between the two is what was causing the skeleton to come out visibly rotated relative to
    /// the wall.
    let deviceOrientation: UIDeviceOrientation

    /// Bundles this frame's depth data into a `BodyPose3DExtractor.DepthGroundingContext`, so
    /// Step 4 can ground the reconstructed skeleton in the SAME real depth data the wall mesh
    /// itself is built from — nil if depth wasn't captured for this frame (e.g. past the
    /// RecordedFrameStore cap).
    var depthGroundingContext: BodyPose3DExtractor.DepthGroundingContext? {
        guard let depthMap else { return nil }
        return BodyPose3DExtractor.DepthGroundingContext(
            cameraTransform: cameraTransform,
            intrinsics: intrinsics,
            imageResolution: imageResolution,
            depthMap: depthMap,
            confidenceMap: confidenceMap,
            deviceOrientation: deviceOrientation
        )
    }
}

/// In-memory-only store (per MVP scope: no cross-session persistence). Frames are indexed by
/// ARKit session time (`ARFrame.timestamp`) so Step 4 can look up "what was the depth/camera
/// state at this exact moment in the video."
///
/// IMPORTANT GOTCHA: ARKit's `CVPixelBuffer`s (captured image, depth map, confidence map) come
/// from a reused buffer pool. Simply holding a reference to `frame.capturedImage` across frames
/// is NOT safe — the underlying memory gets overwritten by later frames, so every "stored" frame
/// would silently end up showing the same (most recent) image. We deep-copy every buffer before
/// storing it (see `copy(_:)`). That copy is real CPU + memory cost per frame, so storage is
/// capped (`maxStoredFrames`) rather than allowed to grow unbounded for long recordings — past
/// the cap we keep recording video via AVFoundation (Step 3 playback still works) but stop
/// storing new depth/transform samples and log a loud, visible warning rather than silently
/// degrading. This cap is a known MVP limitation to tune after on-device memory testing.
final class RecordedFrameStore {
    private(set) var framesByTimestamp: [TimeInterval: RecordedFrameData] = [:]
    private(set) var sortedTimestamps: [TimeInterval] = []
    private(set) var recordingStartTimestamp: TimeInterval?

    let maxStoredFrames: Int
    private var didWarnAboutCap = false

    init(maxStoredFrames: Int = 2700) {
        self.maxStoredFrames = maxStoredFrames
    }

    func reset() {
        framesByTimestamp.removeAll()
        sortedTimestamps.removeAll()
        recordingStartTimestamp = nil
        didWarnAboutCap = false
    }

    func record(_ frame: ARFrame) {
        if recordingStartTimestamp == nil {
            recordingStartTimestamp = frame.timestamp
        }
        guard sortedTimestamps.count < maxStoredFrames else {
            if !didWarnAboutCap {
                didWarnAboutCap = true
                DebugLog.recording.error("RecordedFrameStore hit its \(self.maxStoredFrames, privacy: .public)-frame cap — depth data for the rest of this recording will NOT be available in Step 4. Video playback is unaffected.")
            }
            return
        }
        guard let imageCopy = PixelBufferCopy.copy(frame.capturedImage) else { return }
        // Parens are required here: `frame.sceneDepth?.depthMap.flatMap(...)` lets optional
        // chaining swallow `.flatMap` into the chain, so it tries to call `.flatMap` on the
        // unwrapped `CVPixelBuffer` itself (which has no such member) instead of on the
        // `CVPixelBuffer?` result. Force the optional to resolve first.
        let depthCopy = (frame.sceneDepth?.depthMap).flatMap(PixelBufferCopy.copy)
        let confidenceCopy = (frame.sceneDepth?.confidenceMap).flatMap(PixelBufferCopy.copy)

        let data = RecordedFrameData(
            timestamp: frame.timestamp,
            cameraTransform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageResolution: frame.camera.imageResolution,
            depthMap: depthCopy,
            confidenceMap: confidenceCopy,
            capturedImage: imageCopy,
            deviceOrientation: UIDevice.current.orientation
        )
        framesByTimestamp[frame.timestamp] = data
        sortedTimestamps.append(frame.timestamp)
    }

    /// Finds the stored frame closest to `playbackSeconds` into the clip (0 = first recorded
    /// frame). Logs the lookup delta so association drift is visible during device testing
    /// (success criterion #3).
    func nearestFrame(toPlaybackSeconds playbackSeconds: TimeInterval) -> RecordedFrameData? {
        guard let start = recordingStartTimestamp, !sortedTimestamps.isEmpty else { return nil }
        let target = start + playbackSeconds
        var closest = sortedTimestamps[0]
        var closestDelta = abs(closest - target)
        for t in sortedTimestamps {
            let delta = abs(t - target)
            if delta < closestDelta {
                closest = t
                closestDelta = delta
            }
        }
        let deltaMs = closestDelta * 1000
        DebugLog.recording.info("Frame lookup: playback=\(playbackSeconds, privacy: .public)s -> nearest AR frame delta=\(deltaMs, privacy: .public)ms")
        if closestDelta > 0.1 {
            DebugLog.recording.error("Frame lookup delta exceeds 100ms — depth/video association may be visibly off")
        }
        return framesByTimestamp[closest]
    }

    /// All stored frames within `windowSeconds` of `playbackSeconds`, sorted nearest-first — used
    /// by Step 4's hand-detection fallback (see `ReconstructionHost.generate()`) to search nearby
    /// moments in the SAME clip when the exact paused frame's hands can't be detected (e.g. mid-
    /// grip, occluded by the hold). Does NOT include the exact frame at `playbackSeconds` itself —
    /// callers already have that one from `nearestFrame`.
    func nearbyFrames(toPlaybackSeconds playbackSeconds: TimeInterval, withinSeconds windowSeconds: TimeInterval) -> [RecordedFrameData] {
        guard let start = recordingStartTimestamp else { return [] }
        let target = start + playbackSeconds
        return sortedTimestamps
            .filter { abs($0 - target) <= windowSeconds }
            .sorted { abs($0 - target) < abs($1 - target) }
            .compactMap { framesByTimestamp[$0] }
    }
}

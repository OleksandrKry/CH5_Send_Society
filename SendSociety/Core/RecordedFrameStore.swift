import ARKit
import Foundation

/// One ARKit frame's world-alignment data, captured during Step 3 recording.
struct RecordedFrameData {
    let timestamp: TimeInterval
    let cameraTransform: simd_float4x4
    let depthMap: CVPixelBuffer?
    let confidenceMap: CVPixelBuffer?
    let capturedImage: CVPixelBuffer
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
        guard let imageCopy = Self.copy(frame.capturedImage) else { return }
        let depthCopy = frame.sceneDepth?.depthMap.flatMap(Self.copy)
        let confidenceCopy = frame.sceneDepth?.confidenceMap.flatMap(Self.copy)

        let data = RecordedFrameData(
            timestamp: frame.timestamp,
            cameraTransform: frame.camera.transform,
            depthMap: depthCopy,
            confidenceMap: confidenceCopy,
            capturedImage: imageCopy
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

    private static func copy(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        var copy: CVPixelBuffer?
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &copy)
        guard let destination = copy else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }

        let planeCount = CVPixelBufferGetPlaneCount(buffer)
        if planeCount == 0 {
            if let src = CVPixelBufferGetBaseAddress(buffer), let dst = CVPixelBufferGetBaseAddress(destination) {
                memcpy(dst, src, CVPixelBufferGetDataSize(buffer))
            }
        } else {
            for plane in 0..<planeCount {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(buffer, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { continue }
                let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                memcpy(dst, src, planeHeight * bytesPerRow)
            }
        }
        return destination
    }
}

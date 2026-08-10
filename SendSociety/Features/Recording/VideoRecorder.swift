import AVFoundation
import ARKit
import UIKit

/// Records ARKit's captured camera frames to an .mp4 via AVAssetWriter, and simultaneously
/// stores each frame's camera transform + depth data via `RecordedFrameStore`, keyed by the
/// exact ARKit timestamp — so a paused AVPlayer position can always be traced back to matching
/// depth/transform data (Step 4 depends on this; see success criterion #3).
final class VideoRecorder: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var outputURL: URL?

    let frameStore = RecordedFrameStore()

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStartTimestamp: TimeInterval?
    private var didStartSession = false
    private var wantsRecording = false

    /// Arms the recorder. The AVAssetWriter itself is created lazily on the first frame
    /// (`setUpWriter`) so its video settings can match the real capturedImage dimensions/pixel
    /// format instead of a guessed constant.
    func startRecording() {
        frameStore.reset()
        sessionStartTimestamp = nil
        didStartSession = false
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        wantsRecording = true
        isRecording = true
        DebugLog.recording.info("Recording armed — writer will initialize on first frame")
    }

    /// Call from the shared ARSessionManager's frame callback while `isRecording` is true.
    func append(_ frame: ARFrame) {
        guard wantsRecording else { return }

        if assetWriter == nil {
            setUpWriter(matching: frame.capturedImage)
        }
        guard let writer = assetWriter, let input = videoInput, let adaptor = pixelBufferAdaptor else { return }

        if sessionStartTimestamp == nil {
            sessionStartTimestamp = frame.timestamp
        }
        guard let start = sessionStartTimestamp else { return }
        let presentationTime = CMTime(seconds: frame.timestamp - start, preferredTimescale: 600)

        if !didStartSession {
            writer.startWriting()
            writer.startSession(atSourceTime: presentationTime)
            didStartSession = true
        }

        // Transform/depth are recorded even if the video encoder falls behind — Step 4's
        // world-space accuracy matters more than perfectly gapless encoding for this MVP.
        frameStore.record(frame)

        guard input.isReadyForMoreMediaData else {
            let ts = frame.timestamp
            DebugLog.recording.error("AVAssetWriter input not ready — dropped a video frame at t=\(ts, privacy: .public)")
            return
        }
        adaptor.append(frame.capturedImage, withPresentationTime: presentationTime)
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard wantsRecording else {
            completion(nil)
            return
        }
        wantsRecording = false
        isRecording = false
        guard let writer = assetWriter, let input = videoInput else {
            completion(nil)
            return
        }
        input.markAsFinished()
        writer.finishWriting { [weak self] in
            let count = self?.frameStore.sortedTimestamps.count ?? 0
            DebugLog.recording.info("Recording finished — \(count, privacy: .public) depth/transform samples stored")
            DispatchQueue.main.async {
                completion(self?.outputURL)
            }
        }
    }

    private func setUpWriter(matching pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        outputURL = url

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            // `frame.capturedImage` is ARKit's raw, native-sensor-orientation buffer — always
            // landscape, regardless of how the device is actually held. Without this transform,
            // the written file has no rotation metadata, so any player displays it sideways
            // relative to however it was actually recorded (this is exactly what was reported:
            // "recorded in portrait, but plays back in landscape"). Set once, from the
            // orientation at the moment recording starts — a single video transform can't follow
            // a mid-recording rotation, which is a standard, unavoidable video limitation, not
            // specific to this app.
            input.transform = Self.videoTransform(for: UIDevice.current.orientation)

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(format),
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ]
            )
            writer.add(input)

            assetWriter = writer
            videoInput = input
            pixelBufferAdaptor = adaptor
            DebugLog.recording.info("AVAssetWriter configured \(width, privacy: .public)x\(height, privacy: .public) -> \(url.lastPathComponent, privacy: .public)")
        } catch {
            DebugLog.recording.error("Failed to create AVAssetWriter: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Standard rear-camera-sensor-to-portrait/landscape rotation for tagging a video track's
    /// display orientation. The portrait cases are the common, well-established ones (used here
    /// since this app's primary orientation is portrait); the landscape cases are the same
    /// standard mapping but historically the more error-prone half of this exact API to get
    /// right blind — if a landscape recording plays back rotated, swapping these two cases is
    /// the first thing to try.
    private static func videoTransform(for orientation: UIDeviceOrientation) -> CGAffineTransform {
        switch orientation {
        case .portrait:
            return CGAffineTransform(rotationAngle: .pi / 2)
        case .portraitUpsideDown:
            return CGAffineTransform(rotationAngle: -.pi / 2)
        case .landscapeLeft:
            return CGAffineTransform(rotationAngle: .pi)
        case .landscapeRight:
            return .identity
        default: // faceUp/faceDown/unknown — fall back to portrait, this app's primary orientation
            return CGAffineTransform(rotationAngle: .pi / 2)
        }
    }
}

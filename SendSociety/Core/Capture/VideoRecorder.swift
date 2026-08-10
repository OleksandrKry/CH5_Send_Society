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
    /// Wall-clock length of the just-finished (or in-progress) recording, in seconds — derived
    /// from ARKit frame timestamps rather than re-probed from the written file, since it's already
    /// being tracked here for presentation-time math. Read once, after recording stops, by
    /// `SessionStore.createSession`. Deliberately NOT `@Published`: this is written on every
    /// single ARKit frame (`append(_:)`, up to ~60/sec) while recording, and nothing needs it
    /// live — publishing it anyway would broadcast an `objectWillChange` (and a SwiftUI body
    /// re-evaluation for every view holding this recorder, including the live `ARMeshSceneView`)
    /// on every frame for no reason, stacking needless work onto the same per-frame path that also
    /// deep-copies 2-3 CVPixelBuffers (`RecordedFrameStore.record`) and feeds `AVAssetWriter` —
    /// exactly the kind of overhead worth cutting if recording is crashing/overloading the device.
    private(set) var lastRecordingDuration: TimeInterval = 0
    /// The device orientation captured once, at the same moment `setUpWriter` reads it to build
    /// `videoTransform(for:)` — i.e. the SAME orientation baked into the written file's rotation
    /// metadata. Saved onto `RecordingSession` (see `SessionStore.createSession`) so a later
    /// session-review "Estimate 3D" pass (`SessionReviewView.generateEstimate`) can feed Vision
    /// the EXACT SAME orientation the live pipeline used for this clip, instead of guessing —
    /// using the wrong one here is what was making re-generated postures come out facing the
    /// wrong direction (see `BodyPose3DExtractor.detect(inVideoFrame:deviceOrientation:)`'s doc
    /// comment for the full mechanism).
    @Published private(set) var recordingDeviceOrientation: UIDeviceOrientation = .portrait

    let frameStore = RecordedFrameStore()

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStartTimestamp: TimeInterval?
    private var didStartSession = false
    private var wantsRecording = false
    /// Counts frames seen by `append(_:)` this recording — used ONLY to throttle diagnostic
    /// logging (see `diagnosticLogIntervalFrames`) to roughly once a second instead of every
    /// frame, so the logging added to chase the "crashes during recording" report doesn't itself
    /// reintroduce the kind of per-frame overhead already cut elsewhere (see
    /// `lastRecordingDuration`'s doc comment).
    private var frameCounter = 0
    private let diagnosticLogIntervalFrames = 60
    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        // Closure-based observers (not the `#selector`-based API) since `VideoRecorder` isn't an
        // `NSObject` subclass. Both fire on the main thread and are cheap/event-driven (not
        // per-frame), so no performance concern — but both are exactly the kind of signal that
        // would otherwise be invisible right before a crash: a memory warning means iOS already
        // thinks this process is using too much RAM (the step before a jetsam/OOM kill), and a
        // worsening thermal state means the OS is throttling the CPU/GPU, which can starve ARKit's
        // own tracking (see the "poor slam" log line reported alongside the crash).
        let memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DebugLog.recording.error("Received system memory warning — recording=\(self.isRecording, privacy: .public) \(DeviceDiagnostics.summary, privacy: .public)")
        }
        let thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DebugLog.recording.error("Thermal state changed to \(DeviceDiagnostics.thermalStateDescription, privacy: .public) — recording=\(self.isRecording, privacy: .public)")
        }
        notificationObservers = [memoryObserver, thermalObserver]
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

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
        lastRecordingDuration = 0
        frameCounter = 0
        wantsRecording = true
        isRecording = true
        DebugLog.recording.info("Recording armed — writer will initialize on first frame — baseline \(DeviceDiagnostics.summary, privacy: .public)")
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
        let elapsed = frame.timestamp - start
        lastRecordingDuration = elapsed
        let presentationTime = CMTime(seconds: elapsed, preferredTimescale: 600)

        if !didStartSession {
            writer.startWriting()
            didStartSession = true
            // `startWriting()` can fail (e.g. can't create the output file) without throwing —
            // the only way to find out is checking `.status`/`.error` right after. If this is
            // where things go wrong, every frame from here on is silently dropped (the guard at
            // the top of this function only checks the OPTIONAL writer/input/adaptor exist, not
            // that they're actually in a working state) — logging it here is the difference
            // between seeing that clearly and staring at a mysteriously empty/missing recording.
            if writer.status == .failed {
                DebugLog.recording.error("AVAssetWriter.startWriting() failed: \(String(describing: writer.error), privacy: .public)")
            }
            writer.startSession(atSourceTime: presentationTime)
        }

        // Transform/depth are recorded even if the video encoder falls behind — Step 4's
        // world-space accuracy matters more than perfectly gapless encoding for this MVP.
        frameStore.record(frame)

        frameCounter += 1
        if frameCounter % diagnosticLogIntervalFrames == 0 {
            // Throttled to roughly once/sec (see `diagnosticLogIntervalFrames`'s doc comment) —
            // a timeline of these lines is exactly what shows memory/thermal state climbing (or
            // the writer silently failing) in the run-up to a crash, without flooding the log the
            // way per-frame logging would.
            DebugLog.recording.info("Recording health @ \(elapsed, privacy: .public)s: \(DeviceDiagnostics.summary, privacy: .public) storedFrames=\(self.frameStore.sortedTimestamps.count, privacy: .public) writerStatus=\(writer.status.rawValue, privacy: .public)")
        }

        guard input.isReadyForMoreMediaData else {
            let ts = frame.timestamp
            DebugLog.recording.error("AVAssetWriter input not ready — dropped a video frame at t=\(ts, privacy: .public)")
            return
        }
        if !adaptor.append(frame.capturedImage, withPresentationTime: presentationTime), writer.status == .failed {
            DebugLog.recording.error("AVAssetWriter pixel buffer append failed at t=\(elapsed, privacy: .public)s: \(String(describing: writer.error), privacy: .public)")
        }
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
        DebugLog.recording.info("Recording stopping — \(DeviceDiagnostics.summary, privacy: .public)")
        writer.finishWriting { [weak self] in
            let count = self?.frameStore.sortedTimestamps.count ?? 0
            if writer.status == .failed {
                DebugLog.recording.error("AVAssetWriter.finishWriting completed with .failed status: \(String(describing: writer.error), privacy: .public)")
            }
            DebugLog.recording.info("Recording finished — \(count, privacy: .public) depth/transform samples stored, \(DeviceDiagnostics.summary, privacy: .public)")
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
            let orientation = UIDevice.current.orientation
            recordingDeviceOrientation = orientation
            input.transform = Self.videoTransform(for: orientation)

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

import Foundation
import UIKit

/// RecordingEngine is the "brain" behind the Record Climb screen. It does NOT import SwiftUI and
/// does NOT know about colors, layout, or buttons — it only answers two questions:
///
///   1. "Is the CURRENT camera angle scanned well enough to record from yet?"
///   2. "Should the wall reference be re-saved right now, and was a person in the way?"
///
/// It owns two repeating timers so the View doesn't manage `Timer` objects itself — a redesigned
/// View just needs to call `start()` in `.onAppear`, `stop()` in `.onDisappear`, and read the
/// `@Published` properties below to decide what to show.
///
/// HOW TO WIRE THIS UP:
///   - Read `depthQuality` / `isReadyToRecord` to show "move closer" / "hold steady" / "ready"
///     guidance and to enable/disable the Record button.
///   - Read `wallSaveLogLines` to show the "save mesh attempt N" trail.
///   - Call `attemptWallMeshSave()` once more, directly, at the exact moment Record is tapped —
///     this is IN ADDITION to the automatic periodic saves `start()` sets up, not a replacement.
final class RecordingEngine: ObservableObject {
    /// How often the current camera angle's depth coverage is checked.
    static let depthCheckIntervalSeconds: TimeInterval = 0.5
    /// How often the wall reference is re-saved while the angle is ready and not yet recording.
    static let wallSaveIntervalSeconds: TimeInterval = 1.0
    /// The angle needs at least this much confident depth coverage before Record can be tapped.
    static let readyToRecordDepthThreshold: Double = 0.8
    /// How many "save mesh attempt N" lines stay on screen at once — old ones fall off the top.
    static let maxWallSaveLogLinesShown = 6

    /// How well the CURRENT camera angle is scanned, from 0 to 1. nil until the first check runs.
    @Published private(set) var depthQuality: Double?
    /// "save mesh attempt N (no person detected)" trail — one new line per SUCCESSFUL auto-save.
    /// A skipped attempt (person in frame) adds nothing, on purpose.
    @Published private(set) var wallSaveLogLines: [String] = []

    private let arManager: ARSessionManager
    private let recorder: VideoRecorder

    private var depthCheckTimer: Timer?
    private var wallSaveTimer: Timer?
    /// True while a person-detection check is running — stops a second check from starting
    /// before the first one finishes (Vision requests aren't free, and they'd otherwise pile up).
    private var isWallSaveCheckRunning = false
    /// Counts only SUCCESSFUL saves — what the numbers in `wallSaveLogLines` count up from.
    private var successfulWallSaveCount = 0

    init(arManager: ARSessionManager, recorder: VideoRecorder) {
        self.arManager = arManager
        self.recorder = recorder
    }

    /// True once the current angle has good enough depth coverage to record from.
    var isReadyToRecord: Bool {
        (depthQuality ?? 0) >= Self.readyToRecordDepthThreshold
    }

    /// Starts both repeating checks (depth quality + wall-mesh auto-save). Safe to call more than
    /// once — each call replaces any timers already running.
    func start() {
        depthCheckTimer?.invalidate()
        depthCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.depthCheckIntervalSeconds, repeats: true) { [weak self] _ in
            self?.refreshDepthQuality()
        }

        wallSaveTimer?.invalidate()
        wallSaveTimer = Timer.scheduledTimer(withTimeInterval: Self.wallSaveIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self, self.isReadyToRecord, !self.recorder.isRecording else { return }
            self.attemptWallMeshSave()
        }
    }

    /// Stops both timers.
    func stop() {
        depthCheckTimer?.invalidate()
        depthCheckTimer = nil
        wallSaveTimer?.invalidate()
        wallSaveTimer = nil
    }

    private func refreshDepthQuality() {
        depthQuality = ARSessionManager.depthConfidenceRatio(for: arManager.latestFrame)
    }

    /// Checks the CURRENT camera frame for a person, and — only if no one is in it — re-saves the
    /// wall reference and appends a log line. Called automatically by the repeating timer `start()`
    /// sets up, AND once more, directly, right when Record is tapped — same function, same rule,
    /// two trigger points, so the freshest possible person-free wall reference is always what
    /// actually gets used.
    func attemptWallMeshSave() {
        guard !isWallSaveCheckRunning, let pixelBuffer = arManager.latestFrame?.capturedImage else { return }
        isWallSaveCheckRunning = true
        let deviceOrientation = UIDevice.current.orientation
        PersonPresenceDetector.detectsPerson(in: pixelBuffer, deviceOrientation: deviceOrientation) { [weak self] personIsPresent in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isWallSaveCheckRunning = false
                guard !personIsPresent else { return } // no save, no log line
                self.arManager.captureWallTextureReference()
                self.successfulWallSaveCount += 1
                self.wallSaveLogLines.append("save mesh attempt \(self.successfulWallSaveCount) (no person detected)")
                if self.wallSaveLogLines.count > Self.maxWallSaveLogLinesShown {
                    self.wallSaveLogLines.removeFirst()
                }
            }
        }
    }
}

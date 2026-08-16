//
//  Untitled.swift
//  SendSociety
//
//  Created by Christofer Theodore on 16/08/26.
//

import Foundation
import UIKit

final class RecordingEngineV2: ObservableObject {
    /// How often the current camera angle's depth coverage is checked.
    static let depthCheckIntervalSeconds: TimeInterval = 0.5
    /// How often the wall reference is re-saved while the angle is ready and not yet recording.
    static let wallSaveIntervalSeconds: TimeInterval = 1.0
    /// The angle needs at least this much confident depth coverage before Record can be tapped.
    static let readyToRecordDepthThreshold: Double = 0.8
    /// How many "save mesh attempt N" lines stay on screen at once — old ones fall off the top.
    static let maxWallSaveLogLinesShown = 6
    
    /// How long resumeAfterPause() gives ARKit to relocalize before giving up and telling the
    /// coach to rescan, instead of leaving them staring at "Relocalizing…" forever.
    static let relocalizationTimeoutSeconds: TimeInterval = 6

    /// How well the CURRENT camera angle is scanned, from 0 to 1. nil until the first check runs.
    @Published private(set) var depthQuality: Double?
    /// "save mesh attempt N (no person detected)" trail — one new line per SUCCESSFUL auto-save.
    /// A skipped attempt (person in frame) adds nothing, on purpose.
    @Published private(set) var wallSaveLogLines: [String] = []
    
    /// True if resumeAfterPause() was called but tracking never made it back to .normal within
    /// relocalizationTimeoutSeconds. The View should show a "please rescan the wall" message
    /// instead of normal depth-quality guidance when this is true.
    @Published private(set) var relocalizationTimedOut = false

    private var relocalizationDeadline: Date?

    private let arManager: ARSessionManager
    private let recorder: VideoRecorderEngine

    private var depthCheckTimer: Timer?
    private var wallSaveTimer: Timer?
    /// True while a person-detection check is running — stops a second check from starting
    /// before the first one finishes (Vision requests aren't free, and they'd otherwise pile up).
    private var isWallSaveCheckRunning = false
    /// Counts only SUCCESSFUL saves — what the numbers in `wallSaveLogLines` count up from.
    private var successfulWallSaveCount = 0
    
    /// True once the coach has started recording at least once this session. The wall/mesh
    /// reference should only ever be (re-)captured BEFORE this happens — every recording after the
    /// first must reconstruct against the exact same wall scan the FIRST recording used, not
    /// whatever the camera happens to be pointed at between takes.
    @Published private(set) var hasRecordedAtLeastOnce = false

    /// Call once, right when the coach starts recording for the first time this session — locks in
    /// the wall reference for every recording from here on. Harmless to call again on every later
    /// recording too; it only ever moves one way, false -> true.
    func markRecordingStarted() {
        hasRecordedAtLeastOnce = true
    }

    init(arManager: ARSessionManager, recorder: VideoRecorderEngine) {
        self.arManager = arManager
        self.recorder = recorder
    }

    /// True once the current angle has good enough depth coverage to record from.
    var isReadyToRecord: Bool {
        arManager.trackingQuality == .normal && (depthQuality ?? 0) >= Self.readyToRecordDepthThreshold
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

    /// Call this instead of arManager.resume() directly whenever the coach is about to record
    /// again after a pause. Starts the relocalization countdown that refreshDepthQuality() checks
    /// on its next few ticks.
    func resumeAfterPause() {
        relocalizationTimedOut = false
        relocalizationDeadline = Date().addingTimeInterval(Self.relocalizationTimeoutSeconds)
        arManager.resume()
    }

    private func refreshDepthQuality() {
        depthQuality = ARSessionManager.depthConfidenceRatio(for: arManager.latestFrame)

        guard let deadline = relocalizationDeadline else { return }
        if arManager.trackingQuality == .normal {
            relocalizationDeadline = nil
        } else if Date() > deadline {
            relocalizationTimedOut = true
            relocalizationDeadline = nil
        }
    }

    /// Checks the CURRENT camera frame for a person, and — only if no one is in it — re-saves the
    /// wall reference and appends a log line. Called automatically by the repeating timer `start()`
    /// sets up, AND once more, directly, right when Record is tapped — same function, same rule,
    /// two trigger points, so the freshest possible person-free wall reference is always what
    /// actually gets used.
    func attemptWallMeshSave() {
        guard !hasRecordedAtLeastOnce, !isWallSaveCheckRunning, let pixelBuffer = arManager.latestFrame?.capturedImage else { return }
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

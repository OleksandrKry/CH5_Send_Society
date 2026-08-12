import SwiftUI
import ARKit
import simd
import SwiftData

/// Root navigation for the 4-step MVP pipeline. Owns the single shared ARSessionManager
/// instance for the lifetime of the app so Steps 1-3 always see the same ARSession (see
/// ARSessionManager's doc comment for why this matters).
///
/// This view is now only ever reached via `LibraryView`'s "New Recording" entry point, and always
/// returns to it when the flow finishes (see `onFinished`) — see `LibraryView`'s doc comment for
/// the overall navigation shape.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var arManager = ARSessionManager()
    @State private var step: AppStep = .wallScan
    @State private var calibration: CalibrationResult?
    @State private var reconstructionInput: ReconstructionInput?

    // Owned here (not inside RecordingView) so navigating Step 4 -> back -> Step 3 re-shows the
    // already-recorded clip for a re-pick instead of losing it and dropping back to record/stop.
    @StateObject private var recorder = VideoRecorder()
    @State private var recordedURL: URL?

    /// Lazily constructed once `modelContext` is available (it isn't yet during `init`, since
    /// `@Environment` values aren't resolved until the view is actually part of the hierarchy).
    @State private var sessionStore: SessionStore?
    /// The `RecordingSession` for THIS run through the pipeline, created the moment Step 3
    /// finishes recording (as soon as there's a video + whatever wall scan/calibration data
    /// exists to save alongside it) — see requirement #3's "every state should be saved." Every
    /// video annotation and 3D reconstruction made for the rest of this flow gets folded into this
    /// same session object.
    @State private var currentSession: RecordingSession?
    /// Non-nil when `createSessionIfNeeded` fails — drives a blocking alert (see `body`) so a save
    /// failure is visible ON SCREEN rather than only in a console log (which needs a tethered
    /// device to read). Added after exactly this happened silently: a full recording -> Step 4 ->
    /// Done flow completed with no visible error, and the coach found an empty Library list with no
    /// way to tell why. The recording/reconstruction flow itself still works even when this fires —
    /// `currentSession` just stays nil, so nothing from this run gets persisted (see
    /// `ReconstructionHost.upsertReconstruction()`'s nil-session no-op).
    @State private var saveErrorMessage: String?
    /// Called when the coach is done with this recording (explicit "Done" from Step 4, or backing
    /// out) — returns to `LibraryView`. Set by whichever parent presented this view.
    var onFinished: () -> Void = {}

    var body: some View {
        Group {
            if !LiDARSupport.isSupported {
                unsupportedDeviceView
            } else {
                stepContent
            }
        }
        .onAppear {
            if sessionStore == nil {
                sessionStore = SessionStore(modelContext: modelContext)
            }
        }
        .alert(
            "Couldn't Save Recording",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { isPresented in if !isPresented { saveErrorMessage = nil } }
            ),
            presenting: saveErrorMessage
        ) { _ in
            Button("OK") { saveErrorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .wallScan:
            WallScanView(arManager: arManager) {
                step = .calibration
            }
        case .calibration:
            CalibrationView(arManager: arManager) { result in
                calibration = result
                step = .recording
            }
        case .recording:
            RecordingView(arManager: arManager, recorder: recorder, recordedURL: $recordedURL, session: currentSession, sessionStore: sessionStore) { url, frameStore, pausedSeconds in
                reconstructionInput = ReconstructionInput(videoURL: url, frameStore: frameStore, pausedSeconds: pausedSeconds)
                step = .reconstruction
            }
            .onChange(of: recordedURL) { _, newValue in
                createSessionIfNeeded(videoTempURL: newValue)
            }
        case .reconstruction:
            if let input = reconstructionInput {
                ReconstructionHost(arManager: arManager, input: input, session: currentSession, sessionStore: sessionStore, onBack: {
                    // recordedURL is still set (owned by ContentView), so re-entering .recording
                    // goes straight back to the scrubber instead of the record button.
                    step = .recording
                }, onFinished: onFinished)
            }
        }
    }

    /// Saves the just-recorded video (plus whatever wall scan/calibration data exists so far) as a
    /// new `RecordingSession` the moment recording stops — see `currentSession`'s doc comment.
    /// Guarded so navigating back to Step 3 and stopping a re-record doesn't create a second
    /// session for what's still conceptually the same pipeline run (a coach who genuinely wants a
    /// separate session re-records from Library's "New Recording" instead).
    private func createSessionIfNeeded(videoTempURL: URL?) {
        guard let videoTempURL, currentSession == nil, let sessionStore else { return }
        let title = "Climb — " + Date().formatted(date: .abbreviated, time: .shortened)
        do {
            currentSession = try sessionStore.createSession(
                title: title,
                videoTempURL: videoTempURL,
                videoDurationSeconds: recorder.lastRecordingDuration,
                recordingDeviceOrientationRawValue: recorder.recordingDeviceOrientation.rawValue,
                wallTextureReference: arManager.wallTextureReference,
                calibration: calibration
            )
        } catch {
            // See `saveErrorMessage`'s doc comment — this used to fail completely silently, with
            // the recording/reconstruction flow continuing to work normally and just quietly never
            // persisting anything, which is indistinguishable from "it worked" until you go back to
            // an empty Library list. `error.localizedDescription` on a `CocoaError` from
            // `FileManager` (the likely failure here — see `SessionFileStore`) is usually specific
            // enough to act on directly, e.g. "There isn't enough space" for a full disk.
            let description = error.localizedDescription
            saveErrorMessage = "This recording's video couldn't be saved, so it won't appear in your library: \(description)"
            DebugLog.recording.error("createSessionIfNeeded failed: \(description, privacy: .public)")
        }
    }

    private var unsupportedDeviceView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("LiDAR Required")
                .font(.title2.bold())
            Text("This app needs a LiDAR-equipped iPad to scan the wall and reconstruct 3D pose. This device doesn't support scene reconstruction.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .onAppear {
            DebugLog.general.error("Launched on a device without LiDAR scene-reconstruction support — refusing to proceed")
        }
    }
}

/// Bundled hand-off data from Step 3 into Step 4.
struct ReconstructionInput {
    let videoURL: URL
    let frameStore: RecordedFrameStore
    let pausedSeconds: TimeInterval
}

/// Runs the Step 4 Vision request for the paused frame once, then hosts ReconstructionView.
/// Kept separate from ContentView so the Vision call happens exactly once per "Generate" tap
/// rather than on every SwiftUI body re-evaluation.
private struct ReconstructionHost: View {
    let arManager: ARSessionManager
    let input: ReconstructionInput
    /// The current pipeline run's session, if saving succeeded (see `ContentView.currentSession`)
    /// — nil is handled gracefully throughout (every save call below just no-ops), so a wall-scan
    /// or video-migration failure earlier in the flow doesn't block Step 4 from working, just from
    /// persisting.
    let session: RecordingSession?
    let sessionStore: SessionStore?
    let onBack: () -> Void
    var onFinished: () -> Void = {}

    @State private var poseSample: BodyPoseSample?
    @State private var cameraTransform: simd_float4x4 = matrix_identity_float4x4
    /// See `ReconstructionView.cameraTransform`'s doc comment — nil unless `generate()` just ran a
    /// fresh detection against real stored frame data, so `ReconstructionView` never seeds its
    /// camera from a meaningless placeholder transform.
    @State private var recordingCameraTransform: simd_float4x4?
    @State private var depthContext: BodyPose3DExtractor.DepthGroundingContext?
    /// Classify-then-snap-to-preset results for each limb — see `GripClassifier`. Each is
    /// computed for the exact paused frame first; if confidence comes in below
    /// `GripClassifier.confidenceThreshold`, `generate()`'s nearby-frame fallback (mirroring the
    /// approach already used for raw hand-position recovery) searches nearby moments in the same
    /// clip for a more confident answer for THAT specific limb.
    @State private var leftGrip: GripClassification?
    @State private var rightGrip: GripClassification?
    @State private var leftFoot: FootClassification?
    @State private var rightFoot: FootClassification?
    /// Non-nil only when the corresponding classification above was recovered from a nearby frame
    /// instead of the exact paused one — surfaced in the UI as an explicit "estimated from Xs
    /// earlier/later" label.
    @State private var leftGripOffsetSeconds: TimeInterval?
    @State private var rightGripOffsetSeconds: TimeInterval?
    @State private var leftFootOffsetSeconds: TimeInterval?
    @State private var rightFootOffsetSeconds: TimeInterval?
    @State private var poseError: String?
    @State private var isReady = false

    /// Set either by loading an existing `ReconstructionEntry` near `input.pausedSeconds`, or by
    /// computing fresh detected positions after a successful Vision call — see `generate()`. This
    /// is what actually gets rendered (via `ReconstructionView.initialWorldPositions`) AND what
    /// every subsequent `upsertReconstruction()` call writes back as `ReconstructionEntry
    /// .worldPositions` — it's the stable "auto-detected baseline," never the coach's edits.
    @State private var entryBaseWorldPositions: [BodyJointName: SIMD3<Float>] = [:]
    @State private var entryTimestamp: Double = 0
    /// True once a saved `ReconstructionEntry` was found and loaded for this exact paused moment —
    /// when true, Vision is never run at all (see `generate()` and `RecordingSession`'s doc comment
    /// on why a previously-unanalyzed timestamp in a revisited session can't get a NEW
    /// reconstruction after the fact — this isn't that case, since the coach paused at the same
    /// spot a reconstruction already exists for).
    @State private var loadedFromSavedEntry = false
    @State private var initialWorldPositions: [BodyJointName: SIMD3<Float>]?
    @State private var initialJointOverrides: [BodyJointName: SIMD3<Float>]?
    @State private var initialAnnotationStrokes: [AnnotationStroke] = []
    /// Mirrors of whatever `ReconstructionView` currently has for these — updated by its
    /// onChange callbacks, and written into the saved `ReconstructionEntry` on every change (see
    /// `upsertReconstruction()`).
    @State private var lastJointOverrides: [BodyJointName: SIMD3<Float>]?
    @State private var lastAnnotationStrokes: [AnnotationStroke] = []

    var body: some View {
        Group {
            if isReady {
                ReconstructionView(
                    // wallMeshSnapshot (frozen at Step 1 "Done"), NOT the live meshAnchors —
                    // see ARSessionManager.wallMeshSnapshot for why: the live list keeps growing
                    // through Steps 2-3 and picks up floor/clutter/residual body-shaped mesh.
                    wallAnchors: arManager.wallMeshSnapshot,
                    wallTextureReference: arManager.wallTextureReference,
                    poseSample: poseSample,
                    cameraTransform: recordingCameraTransform,
                    depthContext: depthContext,
                    leftGrip: leftGrip,
                    rightGrip: rightGrip,
                    leftFoot: leftFoot,
                    rightFoot: rightFoot,
                    leftGripOffsetSeconds: leftGripOffsetSeconds,
                    rightGripOffsetSeconds: rightGripOffsetSeconds,
                    leftFootOffsetSeconds: leftFootOffsetSeconds,
                    rightFootOffsetSeconds: rightFootOffsetSeconds,
                    poseError: poseError,
                    onBack: onBack,
                    onFinished: onFinished,
                    initialAnnotationStrokes: initialAnnotationStrokes,
                    onAnnotationStrokesChanged: { strokes in
                        lastAnnotationStrokes = strokes
                        upsertReconstruction()
                    },
                    initialWorldPositions: initialWorldPositions,
                    initialJointOverrides: initialJointOverrides,
                    onJointOverridesChanged: { overrides in
                        lastJointOverrides = overrides
                        upsertReconstruction()
                    }
                )
            } else {
                ProgressView("Reconstructing…")
            }
        }
        .onAppear(perform: generate)
    }

    /// Writes the current in-memory reconstruction state (baseline + any edit/annotations) back
    /// into `session`, if one exists — called after a fresh "Generate" succeeds, and again every
    /// time the coach drags a joint or marks up the view. No-ops silently if there's no session to
    /// save into (see `session`'s doc comment).
    private func upsertReconstruction() {
        guard let session, let sessionStore else { return }
        let entry = ReconstructionEntry(
            timestampSeconds: entryTimestamp,
            worldPositions: entryBaseWorldPositions,
            jointOverrides: lastJointOverrides,
            leftGrip: leftGrip,
            rightGrip: rightGrip,
            leftFoot: leftFoot,
            rightFoot: rightFoot,
            leftGripOffsetSeconds: leftGripOffsetSeconds,
            rightGripOffsetSeconds: rightGripOffsetSeconds,
            leftFootOffsetSeconds: leftFootOffsetSeconds,
            rightFootOffsetSeconds: rightFootOffsetSeconds,
            annotationStrokes: lastAnnotationStrokes
        )
        session.upsertReconstruction(entry)
        sessionStore.save()
    }

    private func generate() {
        entryTimestamp = input.pausedSeconds

        // A reconstruction already exists for (near enough) this exact paused moment — load it
        // directly rather than re-running Vision. This is a "load," not a "regenerate": see
        // `RecordingSession.swift`'s `ReconstructionEntry` doc comment for why a NEW reconstruction
        // at a previously-unanalyzed timestamp isn't possible after the live AR session ends, but
        // that's not what's happening here since a saved entry for this exact spot already exists.
        if let session, let existing = session.reconstructions.first(where: { abs($0.timestampSeconds - input.pausedSeconds) <= 0.3 }) {
            entryTimestamp = existing.timestampSeconds
            entryBaseWorldPositions = existing.worldPositions
            initialWorldPositions = existing.worldPositions
            initialJointOverrides = existing.jointOverrides
            lastJointOverrides = existing.jointOverrides
            initialAnnotationStrokes = existing.annotationStrokes
            lastAnnotationStrokes = existing.annotationStrokes
            leftGrip = existing.leftGrip
            rightGrip = existing.rightGrip
            leftFoot = existing.leftFoot
            rightFoot = existing.rightFoot
            leftGripOffsetSeconds = existing.leftGripOffsetSeconds
            rightGripOffsetSeconds = existing.rightGripOffsetSeconds
            leftFootOffsetSeconds = existing.leftFootOffsetSeconds
            rightFootOffsetSeconds = existing.rightFootOffsetSeconds
            loadedFromSavedEntry = true
            isReady = true
            DebugLog.reconstruction.info("Loaded saved reconstruction for t=\(existing.timestampSeconds, privacy: .public)s — skipping Vision")
            return
        }

        // The actual detection/grounding/classification algorithm lives in
        // `LiveReconstructionGenerator` (Core/PoseReconstruction) — this just wires this screen's
        // input/state to it and copies the result back out. See that type's doc comment for why it
        // was pulled out of here.
        do {
            // `session?.calibration?.segments` are the climber's Step 2 measured limb lengths
            // (nil if Step 2 was skipped) — see `CalibrationScaleCorrection`'s doc comment for why
            // this frame's own detection needs them to correct its bone proportions.
            let result = try LiveReconstructionGenerator.generate(
                input: input,
                wallReference: arManager.wallTextureReference,
                calibratedSegments: session?.calibration?.segments
            )
            cameraTransform = result.cameraTransform
            // Separate from `cameraTransform` above (which stays non-optional and feeds
            // classification math) — this is specifically "do we have a REAL per-frame recording
            // transform to seed the 3D-view camera with," passed straight through to
            // `ReconstructionView`. Only ever set here, on the fresh-detection path — stays nil for
            // a loaded saved entry (see the early return above) or if generation threw, neither of
            // which has a trustworthy per-frame camera pose to seed a camera from.
            recordingCameraTransform = result.cameraTransform
            depthContext = result.depthContext
            poseSample = result.poseSample
            poseError = result.poseError
            leftGrip = result.leftGrip
            rightGrip = result.rightGrip
            leftFoot = result.leftFoot
            rightFoot = result.rightFoot
            leftGripOffsetSeconds = result.leftGripOffsetSeconds
            rightGripOffsetSeconds = result.rightGripOffsetSeconds
            leftFootOffsetSeconds = result.leftFootOffsetSeconds
            rightFootOffsetSeconds = result.rightFootOffsetSeconds

            if let worldPositions = result.worldPositions {
                // Freshly generated (not loaded) — save it right away, per feedback item #2's
                // "indicator in specific frame if that's already 3d generated": this is the moment
                // a scrubber tick mark should appear for this timestamp. `entryBaseWorldPositions`
                // is the baseline every later edit/annotation upsert writes on top of (see
                // `upsertReconstruction()`).
                entryBaseWorldPositions = worldPositions
                // Render from these FINAL, calibration-retargeted positions directly, matching the
                // loaded-saved-entry path above (`initialWorldPositions = existing.worldPositions`).
                // The old behavior left this unset here, so `ReconstructionView` fell back to
                // re-deriving positions from `poseSample` — which skips retargeting, and for a
                // YOLO-generated result is impossible outright since `poseSample` is always nil
                // there. See `LiveReconstructionGenerator.Result.worldPositions`'s doc comment.
                initialWorldPositions = worldPositions
                upsertReconstruction()
            }
        } catch LiveReconstructionGenerator.GenerationError.noStoredFrameData {
            poseError = "No stored depth/camera data for this moment in the video."
        } catch LiveReconstructionGenerator.GenerationError.couldNotReadFrame {
            poseError = "Couldn't read this frame from the recording — try a different moment in the video."
        } catch {
            poseError = "Something went wrong generating this reconstruction — try a different moment in the video."
            let description = String(describing: error)
            DebugLog.reconstruction.error("LiveReconstructionGenerator.generate threw an unexpected error: \(description, privacy: .public)")
        }

        isReady = true
    }
}

import SwiftUI
import ARKit
import simd
import SwiftData

/// Root navigation for the 2-step MVP pipeline (record, then reconstruct). Owns the single shared ARSessionManager
/// instance for the lifetime of the app so every step always sees the same ARSession (see
/// ARSessionManager's doc comment for why this matters).
///
/// This view is now only ever reached via `LibraryView`'s "New Recording" entry point, and always
/// returns to it when the flow finishes (see `onFinished`) — see `LibraryView`'s doc comment for
/// the overall navigation shape.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var arManager = ARSessionManager()
    @State private var step: AppStep = .recording
    @State private var reconstructionInput: ReconstructionInput?

    // Owned here (not inside RecordingView) so navigating Step 4 -> back -> Step 3 re-shows the
    // already-recorded clip for a re-pick instead of losing it and dropping back to record/stop.
    @StateObject private var recorder = VideoRecorder()
    @State private var recordedURL: URL?

    /// Lazily constructed once `modelContext` is available (it isn't yet during `init`, since
    /// `@Environment` values aren't resolved until the view is actually part of the hierarchy).
    @State private var sessionStore: SessionStore?
    /// The `RecordingSession` for THIS run through the pipeline, created the moment recording
    /// finishes (as soon as there's a video + whatever wall scan data exists to save alongside
    /// it) — see requirement #3's "every state should be saved." Every
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

    /// Saves the just-recorded video (plus whatever wall scan data exists so far) as a
    /// new `RecordingSession` the moment recording stops — see `currentSession`'s doc comment.
    /// Guarded so navigating back to the recording step and stopping a re-record doesn't create a
    /// second session for what's still conceptually the same pipeline run (a coach who genuinely
    /// wants a separate session re-records from Library's "New Recording" instead).
    private func createSessionIfNeeded(videoTempURL: URL?) {
        guard let videoTempURL, currentSession == nil, let sessionStore else { return }
        let title = "Climb — " + Date().formatted(date: .abbreviated, time: .shortened)
        do {
            currentSession = try sessionStore.createSession(
                title: title,
                videoTempURL: videoTempURL,
                videoDurationSeconds: recorder.lastRecordingDuration,
                recordingDeviceOrientationRawValue: recorder.recordingDeviceOrientation.rawValue,
                wallTextureReference: arManager.wallTextureReference
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

/// Hosts `ReconstructionView` for Step 4, and runs the "load an existing 3D pose, or detect a
/// new one" decision exactly once per "Generate" tap (via `.onAppear`) rather than on every
/// SwiftUI body re-evaluation.
///
/// THIS FILE IS UI ONLY for that decision — it never talks to `LiveReconstructionGenerator` or
/// `RecordingSession.reconstructions` directly, it asks `ReconstructionHostEngine` (see that
/// file) to do it, and just holds the answer in `result`.
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

    /// Everything needed to render the 3D view, once `loadOrGenerateReconstruction()` has run —
    /// nil beforehand, which is what shows the "Reconstructing…" spinner.
    @State private var result: ReconstructionResult?
    /// Mirrors of whatever `ReconstructionView` currently has for these — updated by its
    /// onChange callbacks, and written into the saved `ReconstructionEntry` on every change (see
    /// `saveCurrentReconstruction()`).
    @State private var currentJointOverrides: [BodyJointName: SIMD3<Float>]?
    @State private var currentAnnotationStrokes: [AnnotationStrokeModel] = []

    var body: some View {
        Group {
            if let result {
                ReconstructionView(
                    // wallMeshSnapshot (frozen the moment recording starts), NOT the live meshAnchors —
                    // see ARSessionManager.wallMeshSnapshot for why: the live list keeps growing
                    // through Steps 2-3 and picks up floor/clutter/residual body-shaped mesh.
                    wallAnchors: arManager.wallMeshSnapshot,
                    wallTextureReference: arManager.wallTextureReference,
                    poseSample: result.poseSample,
                    cameraTransform: result.cameraTransform,
                    depthContext: result.depthContext,
                    poseError: result.poseError,
                    onBack: onBack,
                    onFinished: onFinished,
                    initialAnnotationStrokes: result.initialAnnotationStrokes,
                    onAnnotationStrokesChanged: { strokes in
                        currentAnnotationStrokes = strokes
                        saveCurrentReconstruction()
                    },
                    initialWorldPositions: result.initialWorldPositions,
                    initialJointOverrides: result.initialJointOverrides,
                    onJointOverridesChanged: { overrides in
                        currentJointOverrides = overrides
                        saveCurrentReconstruction()
                    }
                )
            } else {
                ProgressView("Reconstructing…")
            }
        }
        .onAppear(perform: loadOrGenerateReconstruction)
    }

    private func loadOrGenerateReconstruction() {
        let newResult = ReconstructionHostEngine.loadOrGenerate(input: input, session: session, wallReference: arManager.wallTextureReference)
        result = newResult
        currentJointOverrides = newResult.initialJointOverrides
        currentAnnotationStrokes = newResult.initialAnnotationStrokes

        // Freshly generated (not loaded from a save) — save it right away, so a scrubber marker
        // appears for this timestamp immediately rather than only after the coach edits something.
        if !newResult.wasLoadedFromSavedEntry, newResult.initialWorldPositions != nil {
            saveCurrentReconstruction()
        }
    }

    /// Writes the current in-memory reconstruction state (baseline + any edit/annotations) back
    /// into `session` — called right after a fresh "Generate" succeeds, and again every time the
    /// coach drags a joint or marks up the view. Delegates the actual save to
    /// `ReconstructionHostEngine`, which no-ops if there's no session to save into.
    private func saveCurrentReconstruction() {
        guard let result else { return }
        ReconstructionHostEngine.save(
            session: session,
            sessionStore: sessionStore,
            timestampSeconds: result.timestampSeconds,
            baseWorldPositions: result.baseWorldPositions,
            jointOverrides: currentJointOverrides,
            annotationStrokes: currentAnnotationStrokes
        )
    }
}

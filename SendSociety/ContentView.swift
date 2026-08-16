import SwiftUI
import ARKit
import simd
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var arManager = ARSessionManager()

    @StateObject private var recorder = VideoRecorderEngine()
    @State private var recordedURL: URL?

    @State private var sessionController: SessionStoreV2?
    @State private var recordingSession: RecordingSessionV2?
    
    @State private var saveErrorMessage: String?
    
    var onFinished: () -> Void = {}

    var body: some View {
        Group {
            if !LiDARSupport.isSupported {
                unsupportedDeviceView
            } else {
                recordingScreen
            }
        }
        .onAppear {
            if sessionController == nil {
                sessionController = SessionStoreV2(modelContext: modelContext)
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
    private var recordingScreen: some View {
        RecordingViewV2(arManager: arManager, recorder: recorder, recordedURL: $recordedURL, recordingSession: recordingSession, sessionController: sessionController, onSessionDone: onFinished)
            .onChange(of: recordedURL) { _, newValue in
                guard let newValue else { return }
                addVideoAttempt(videoTempURL: newValue)
                recordedURL = nil
            }
    }

    private func addVideoAttempt(videoTempURL: URL) {
        guard let sessionController else { return }
        do {
            let session = try recordingSession ?? sessionController.createSession(
                title: "Climb — " + Date().formatted(date: .abbreviated, time: .shortened),
                wallTextureReference: arManager.wallTextureReference
            )
            recordingSession = session
            
            
            
            try sessionController.addVideoAttempt(
                to: session,
                videoTempURL: videoTempURL,
                videoDurationSeconds: recorder.lastRecordingDuration,
                recordingDeviceOrientationRawValue: recorder.recordingDeviceOrientation.rawValue,
                clipStartTimestamp: recorder.sessionStartTimestamp ?? 0
            )
            DebugLog.recording.info("Session created: id=\(session.id, privacy: .public), owner=\(session.ownerID, privacy: .public), title=\(session.title, privacy: .public)")
        } catch {
            let description = error.localizedDescription
            saveErrorMessage = "This recording's video couldn't be saved, so it won't appear in your library: \(description)"
            DebugLog.recording.error("addVideoAttempt failed: \(description, privacy: .public)")
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

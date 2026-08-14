import SwiftUI
import ARKit
import AVKit

/// Step 2 — Record the Climb. Point the camera at the wall until the angle is scanned well
/// enough, then tap Record. Once a clip exists, this screen hands off to `PlaybackView` to review
/// it.
///
/// THIS FILE IS UI ONLY. It never checks depth coverage or runs the person-detection wall-save
/// itself — it asks `RecordingEngine` (see that file) for answers, and asks `arManager`/`recorder`
/// (both already plain, non-SwiftUI "engines" of their own) to actually run the AR session and
/// record video. If you're redesigning this screen's look, this is the only file you should need
/// to touch.
struct RecordingView: View {
    // MARK: - Given to this screen from outside

    @ObservedObject var arManager: ARSessionManager
    // Recorder + recorded URL are owned by ContentView (not this view) and passed in, so that
    // coming back here from Step 3 ("pick a different moment") re-shows the already-recorded
    // clip instead of losing it and dropping back to the record button.
    @ObservedObject var recorder: VideoRecorder
    @Binding var recordedURL: URL?
    /// The session this recording was saved into, and the store to persist further changes
    /// through — both nil until the session is actually created (right after recording stops),
    /// and nil forever if saving failed. `PlaybackView` treats both as "annotation/markers
    /// unavailable" rather than erroring.
    let session: RecordingSession?
    let sessionStore: SessionStore?
    let onGenerate: (URL, RecordedFrameStore, TimeInterval) -> Void

    // MARK: - The "brain" this screen talks to

    /// Tracks depth-scan quality and runs the person-gated wall-mesh auto-save. Plain Swift, no
    /// SwiftUI — see `RecordingEngine.swift`.
    @StateObject private var engine: RecordingEngine

    // MARK: - Plain on-screen state (just "what's toggled," no logic)

    /// OFF by default — a developer toggle to check how the AR mesh is holding up; normal
    /// coaches never need to see it.
    @State private var showMesh = DeveloperSettings.showMesh

    init(arManager: ARSessionManager, recorder: VideoRecorder, recordedURL: Binding<URL?>, session: RecordingSession?, sessionStore: SessionStore?, onGenerate: @escaping (URL, RecordedFrameStore, TimeInterval) -> Void) {
        self.arManager = arManager
        self.recorder = recorder
        self._recordedURL = recordedURL
        self.session = session
        self.sessionStore = sessionStore
        self.onGenerate = onGenerate
        _engine = StateObject(wrappedValue: RecordingEngine(arManager: arManager, recorder: recorder))
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let recordedURL {
                PlaybackViewV2(url: recordedURL, frameStore: recorder.frameStore, session: session, sessionStore: sessionStore, onGenerate: onGenerate)
            } else {
                ARMeshSceneView(session: arManager.session, showMesh: showMesh)
                    .ignoresSafeArea()
                controls
                MeshToggleButton(showMesh: $showMesh)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding()
            }
        }
        .onAppear {
            // This is the first screen the app shows (no separate wall-scan screen), so this is
            // the only place that needs to start the ARSession — `startIfNeeded()`'s own guard
            // makes this safe to call even if something else already started it.
            arManager.startIfNeeded()
            arManager.onFrameUpdate = { [weak recorder] frame in
                recorder?.append(frame)
            }
            engine.start()
        }
        .onDisappear {
            arManager.onFrameUpdate = nil
            engine.stop()
        }
    }

    // MARK: - Controls: guidance text, wall-save log, record button

    private var controls: some View {
        VStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Point at the Wall").font(.headline)
                readinessGuidance
                wallSaveLog
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()

            Spacer()

            recordButton
                .disabled(!engine.isReadyToRecord && !recorder.isRecording)
                .opacity((!engine.isReadyToRecord && !recorder.isRecording) ? 0.4 : 1)
                .padding(.bottom, 40)
        }
    }

    /// "Move closer" / "hold steady" / "ready" guidance, driven entirely by `engine.depthQuality`.
    @ViewBuilder
    private var readinessGuidance: some View {
        let quality = engine.depthQuality ?? 0
        Group {
            if recorder.isRecording {
                Text("Recording…")
            } else if engine.depthQuality == nil {
                Text("Point the camera at the wall to begin")
            } else if quality < 0.5 {
                Text("Move closer to the wall")
            } else if quality < RecordingEngine.readyToRecordDepthThreshold {
                Text("Almost there — hold steady")
            } else {
                Text("Ready — tap Record")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    /// The "save mesh attempt N (no person detected)" trail, straight from `engine.wallSaveLogLines`.
    @ViewBuilder
    private var wallSaveLog: some View {
        if !engine.wallSaveLogLines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(engine.wallSaveLogLines, id: \.self) { line in
                    Text(line)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: recorder.isRecording ? 6 : 30)
                    .fill(.red)
                    .frame(width: recorder.isRecording ? 30 : 62, height: recorder.isRecording ? 30 : 62)
                    .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
            }
        }
    }

    // MARK: - Actions
    // The function a redesigned View's Record button should call.

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stopRecording { url in
                recordedURL = url
            }
        } else {
            // One more save attempt, same person-gated rule as the periodic auto-save, right as
            // recording actually starts — see `RecordingEngine.attemptWallMeshSave()`'s doc
            // comment for why this runs in ADDITION to the automatic timer, not instead of it.
            engine.attemptWallMeshSave()
            recorder.startRecording()
        }
    }
}

// Preview note: with `session`/`sessionStore` nil and no recorded URL yet, this shows the
// pre-recording state (live mesh view + record button) — the post-recording `PlaybackView` state
// has its own preview in that file.
#Preview {
    RecordingView(
        arManager: ARSessionManager(),
        recorder: VideoRecorder(),
        recordedURL: .constant(nil),
        session: nil,
        sessionStore: nil
    ) { _, _, _ in }
}

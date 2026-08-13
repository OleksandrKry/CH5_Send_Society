import SwiftUI
import ARKit
import AVKit

/// Step 2 — Record the Climb. This is the app's only pre-recording screen: there's no separate
/// wall-scan step anymore, so this screen does both jobs — gate the Record button on the CURRENT
/// camera angle having good enough depth coverage (`ARSessionManager.depthConfidenceRatio`), show
/// move-closer/hold-steady guidance, and keep the wall reference
/// (`ARSessionManager.captureWallTextureReference()`) continuously up to date via a periodic
/// auto-save (`attemptWallMeshSave()`) while the coach is getting the angle right, instead of a
/// single one-shot capture. Uses the SAME shared ARSession (via ARSessionManager.onFrameUpdate) so
/// camera transform + depth are captured alongside the video, keyed by timestamp.
///
/// WALL-MESH AUTO-SAVE: every 1 second, as long as the current angle is "ready" (>= 80% depth
/// confidence) and recording hasn't started, this re-saves the wall reference — so the freshest
/// good angle is always what Step 4 builds the wall mesh from, not whatever the coach happened to
/// be pointing at the FIRST time the angle became ready. Each attempt is skipped (no save, no log
/// line) if `PersonPresenceDetector` finds anyone in frame — baking a person's body into the
/// wall's point-cloud mesh/texture would corrupt it. The exact same check runs one more time right
/// when Record is tapped (see `recordButton`), so the freshest possible, person-free wall
/// reference is what actually gets used, per the coach's own request. Deliberately existence-only,
/// not position-aware (e.g. a second climber off to the side is fine, only someone actually in the
/// shot blocks a save) — see `PersonPresenceDetector`'s doc comment for why.
///
/// NOTE: this used to ALSO require panning up/down to cover the wall's vertical extent (tracking
/// accumulated mesh height, with a real-floor-detection upgrade via
/// `ARSessionManager.detectedFloorY`) — removed again after on-device testing showed the "tilt up
/// to capture the top" guidance getting stuck/flickering unreliably. Only the distance check
/// remains for now; re-adding vertical coverage later should start from a more robust signal than
/// accumulated-mesh min/max Y.
struct RecordingView: View {
    @ObservedObject var arManager: ARSessionManager
    // Recorder + recorded URL are owned by ContentView (not this view) and passed in, so that
    // coming back here from Step 3 ("pick a different moment") re-shows the already-recorded
    // clip instead of losing it and dropping back to the record button.
    @ObservedObject var recorder: VideoRecorder
    @Binding var recordedURL: URL?
    /// The session this recording was saved into (see `ContentView.createSessionIfNeeded`), and
    /// the store to persist further changes through — both nil until the session is actually
    /// created (right after recording stops), and nil forever if saving failed. `PlaybackView`
    /// treats both as "annotation/markers unavailable" rather than erroring.
    let session: RecordingSession?
    let sessionStore: SessionStore?
    let onGenerate: (URL, RecordedFrameStore, TimeInterval) -> Void

    /// OFF by default — see `ARMeshSceneView.showMesh`'s doc comment. A developer toggle to check
    /// how the mesh is holding up; normal coaches never need to see it.
    @State private var showMesh = DeveloperSettings.showMesh
    /// Live "is the CURRENT angle scanned well enough" cue — same signal/cadence this screen's
    /// readiness gate uses.
    @State private var depthQuality: Double?
    @State private var qualityTimer: Timer?
    /// Fires `attemptWallMeshSave()` every 1s while the angle is ready — see this type's doc
    /// comment.
    @State private var wallSaveTimer: Timer?
    /// True while a `PersonPresenceDetector` check is in flight — guards against piling up
    /// concurrent Vision requests if one hasn't finished before the next 1s tick (or a Record tap
    /// mid-tick).
    @State private var wallSaveCheckInFlight = false
    /// Only counts SUCCESSFUL saves (no person detected) — what `wallSaveLogLines` numbers.
    @State private var wallSaveAttemptCount = 0
    /// Rendered below `readinessGuidance` — "save mesh attempt N (no person detected)" per
    /// successful auto-save. Trimmed to the most recent few so a long pre-record phase doesn't
    /// grow this forever. A skipped (person-in-frame) attempt deliberately adds NO line at all.
    @State private var wallSaveLogLines: [String] = []

    /// Whether Record can actually be tapped right now — the CURRENT camera angle needs >= 80%
    /// confident depth coverage before there's enough data to build a usable wall mesh from.
    private var isReadyToRecord: Bool {
        (depthQuality ?? 0) >= 0.8
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let recordedURL {
                PlaybackView(url: recordedURL, frameStore: recorder.frameStore, session: session, sessionStore: sessionStore, onGenerate: onGenerate)
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
            // This is the first screen the app shows (no separate wall-scan screen anymore), so
            // this is the only place that needs to start the ARSession —
            // `ARSessionManager.startIfNeeded()`'s own `didConfigure` guard makes this safe to
            // call even if something else already started it.
            arManager.startIfNeeded()
            arManager.onFrameUpdate = { [weak recorder] frame in
                recorder?.append(frame)
            }
            qualityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                depthQuality = ARSessionManager.depthConfidenceRatio(for: arManager.latestFrame)
            }
            wallSaveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                guard isReadyToRecord, !recorder.isRecording else { return }
                attemptWallMeshSave()
            }
        }
        .onDisappear {
            arManager.onFrameUpdate = nil
            qualityTimer?.invalidate()
            qualityTimer = nil
            wallSaveTimer?.invalidate()
            wallSaveTimer = nil
        }
    }

    /// Runs a `PersonPresenceDetector` check against the CURRENT live frame, and — only if no one
    /// is in it — re-saves the wall reference (`ARSessionManager.captureWallTextureReference()`)
    /// and appends a log line. Called both by the periodic 1s timer (while the angle is ready and
    /// recording hasn't started) and once more directly from `recordButton`'s tap — same function,
    /// same rule, two trigger points. Guarded only by `wallSaveCheckInFlight`, so the tap-triggered
    /// call still completes and saves even if `recorder.isRecording` has already flipped true by
    /// the time the (async) person check resolves — that's the intended "last save on Record tap"
    /// behavior, not a race to avoid.
    private func attemptWallMeshSave() {
        guard !wallSaveCheckInFlight, let pixelBuffer = arManager.latestFrame?.capturedImage else { return }
        wallSaveCheckInFlight = true
        let orientation = UIDevice.current.orientation
        PersonPresenceDetector.detectsPerson(in: pixelBuffer, deviceOrientation: orientation) { personPresent in
            DispatchQueue.main.async {
                wallSaveCheckInFlight = false
                guard !personPresent else { return } // no save, no log line — see this type's doc comment
                arManager.captureWallTextureReference()
                wallSaveAttemptCount += 1
                wallSaveLogLines.append("save mesh attempt \(wallSaveAttemptCount) (no person detected)")
                if wallSaveLogLines.count > 6 {
                    wallSaveLogLines.removeFirst()
                }
            }
        }
    }

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
                .disabled(!isReadyToRecord && !recorder.isRecording)
                .opacity((!isReadyToRecord && !recorder.isRecording) ? 0.4 : 1)
                .padding(.bottom, 40)
        }
    }

    /// "Move closer" / "hold steady" / "ready" guidance so the coach knows whether the CURRENT
    /// camera angle has good enough depth coverage yet, without a separate scanning step.
    @ViewBuilder
    private var readinessGuidance: some View {
        let ratio = depthQuality ?? 0
        Group {
            if recorder.isRecording {
                Text("Recording…")
            } else if depthQuality == nil {
                Text("Point the camera at the wall to begin")
            } else if ratio < 0.5 {
                Text("Move closer to the wall")
            } else if ratio < 0.8 {
                Text("Almost there — hold steady")
            } else {
                Text("Ready — tap Record")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    /// The requested "save mesh attempt N (no person detected)" trail — see
    /// `wallSaveLogLines`'/`attemptWallMeshSave()`'s doc comments. Deliberately renders NOTHING
    /// (not even an empty line) for a skipped, person-in-frame attempt — the log simply doesn't
    /// grow that tick.
    @ViewBuilder
    private var wallSaveLog: some View {
        if !wallSaveLogLines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(wallSaveLogLines, id: \.self) { line in
                    Text(line)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stopRecording { url in
                    recordedURL = url
                }
            } else {
                // One more save attempt, same person-gated rule as the periodic auto-save, right
                // as recording actually starts — see `attemptWallMeshSave()`'s doc comment.
                attemptWallMeshSave()
                recorder.startRecording()
            }
        } label: {
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

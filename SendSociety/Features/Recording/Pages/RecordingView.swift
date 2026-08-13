import SwiftUI
import ARKit
import AVKit

/// Step 3 — Record the Climb. Single Record/Stop button, using the SAME shared ARSession
/// (via ARSessionManager.onFrameUpdate) so camera transform + depth are captured alongside the
/// video, keyed by timestamp.
struct RecordingView: View {
    @ObservedObject var arManager: ARSessionManager
    // Recorder + recorded URL are owned by ContentView (not this view) and passed in, so that
    // coming back here from Step 4 ("pick a different moment") re-shows the already-recorded
    // clip instead of losing it and dropping back to the record button.
    @ObservedObject var recorder: VideoRecorder
    @Binding var recordedURL: URL?
    /// The session this recording was saved into (see `ContentView.createSessionIfNeeded`), and
    /// the store to persist further changes through — both nil until the session is actually
    /// created (right after recording stops), and nil forever if saving failed. `PlaybackView`
    /// treats both as "annotation/markers unavailable" rather than erroring.
    let session: RecordingSession?
    let sessionStore: SessionStore?
    /// True for the "Quick Record" flow (`ContentView.skipWallScan`) — Step 1's separate wall-scan
    /// screen was skipped entirely, so THIS screen has to do both jobs: gate the Record button on
    /// the CURRENT camera angle having good enough depth coverage (same threshold/signal Step 1's
    /// "Depth quality" badge uses — `ARSessionManager.depthConfidenceRatio`), show move-closer/
    /// hold-steady guidance instead of Step 1's mesh-coverage badges, and capture the wall
    /// reference frame (`ARSessionManager.captureWallTextureReference()`) itself, right as
    /// recording actually starts, instead of Step 1's "Done Scanning" button doing it ahead of
    /// time. `false` (the default) preserves Step 3's original always-enabled-record behavior
    /// exactly, with no readiness gate, no guidance text, and no automatic wall-reference capture
    /// (Step 1 already did that before this screen ever appears). Declared BEFORE `onGenerate`
    /// (even though it reads oddly ordered) so `onGenerate` stays the LAST parameter — required
    /// for every call site's trailing-closure syntax to keep working.
    ///
    /// NOTE: this used to ALSO require panning up/down to cover the wall's vertical extent
    /// (tracking accumulated mesh height, with a real-floor-detection upgrade via
    /// `ARSessionManager.detectedFloorY`) — removed again after on-device testing showed the
    /// "tilt up to capture the top" guidance getting stuck/flickering unreliably. Only the
    /// distance check remains for now; re-adding vertical coverage later should start from a more
    /// robust signal than accumulated-mesh min/max Y.
    var requireWallReadiness: Bool = false
    let onGenerate: (URL, RecordedFrameStore, TimeInterval) -> Void

    /// OFF by default — see `ARMeshSceneView.showMesh`'s doc comment. Seeded from
    /// `DeveloperSettings.showMesh` so a developer's choice carries over from/to Step 1's own
    /// `MeshToggleButton`.
    @State private var showMesh = DeveloperSettings.showMesh
    /// Live "is the CURRENT angle scanned well enough" cue, only sampled when
    /// `requireWallReadiness` is true — same signal and cadence as `WallScanView.depthQuality`.
    @State private var depthQuality: Double?
    @State private var qualityTimer: Timer?
    /// Set the first time Record is tapped in a `requireWallReadiness` run, so a coach who stops
    /// and re-starts recording within the same screen visit doesn't re-freeze the wall reference
    /// (and its now-possibly-different camera angle) out from under an already-recorded clip.
    @State private var hasCapturedWallReference = false

    /// Whether Record can actually be tapped right now. Always true when `requireWallReadiness` is
    /// false (Step 3's original behavior). When true, mirrors `WallScanView`'s own "Good" threshold
    /// (>= 80% confident depth) so both screens agree on what "good enough" means.
    private var isReadyToRecord: Bool {
        guard requireWallReadiness else { return true }
        return (depthQuality ?? 0) >= 0.8
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
            // Normally a no-op here: Step 1's `WallScanView` already called this before this
            // screen ever appears (see `ARSessionManager.startIfNeeded()`'s own `didConfigure`
            // guard — calling it twice is safe and cheap). But the Quick Record flow
            // (`ContentView.skipWallScan`) starts `step` at `.recording` directly, so
            // `WallScanView` never mounts at all — without this call, the ARSession would never
            // actually `run()`, and `ARMeshSceneView` would just show a black screen with no
            // camera passthrough, since it attaches to a session nobody ever started.
            arManager.startIfNeeded()
            arManager.onFrameUpdate = { [weak recorder] frame in
                recorder?.append(frame)
            }
            if requireWallReadiness {
                qualityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    depthQuality = ARSessionManager.depthConfidenceRatio(for: arManager.latestFrame)
                }
            }
        }
        .onDisappear {
            arManager.onFrameUpdate = nil
            qualityTimer?.invalidate()
            qualityTimer = nil
        }
    }

    private var controls: some View {
        VStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(requireWallReadiness ? "Point at the Wall" : "Step 3 — Record the Climb").font(.headline)
                if requireWallReadiness {
                    readinessGuidance
                } else {
                    Text("Same continuous AR session — camera transform and depth are captured alongside the video.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
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

    /// "Move closer" / "hold steady" / "ready" guidance in place of Step 1's mesh-coverage badges
    /// — same ratio/threshold breakpoints as `WallScanView.depthQualityBadge`, reworded for a
    /// screen that's ALSO the record button, not a separate scanning step.
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

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stopRecording { url in
                    recordedURL = url
                }
            } else {
                if requireWallReadiness, !hasCapturedWallReference {
                    // The wall structure is saved AT THIS MOMENT — right as recording actually
                    // starts, from whatever angle the coach is currently standing at — instead of
                    // Step 1's separate "Done Scanning" tap ahead of time. See this property's and
                    // `requireWallReadiness`'s doc comments.
                    arManager.captureWallTextureReference()
                    hasCapturedWallReference = true
                }
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

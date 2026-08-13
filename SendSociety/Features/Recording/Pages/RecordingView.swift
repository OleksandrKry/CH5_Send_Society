import SwiftUI
import ARKit
import AVKit

/// Step 2 — Record the Climb. This is the app's only pre-recording screen: there's no separate
/// wall-scan step anymore, so this screen does both jobs — gate the Record button on the CURRENT
/// camera angle having good enough depth coverage (`ARSessionManager.depthConfidenceRatio`), show
/// move-closer/hold-steady guidance, and capture the wall reference frame
/// (`ARSessionManager.captureWallTextureReference()`) itself, right as recording actually starts.
/// Uses the SAME shared ARSession (via ARSessionManager.onFrameUpdate) so camera transform + depth
/// are captured alongside the video, keyed by timestamp.
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
    /// Set the first time Record is tapped, so a coach who stops and re-starts recording within
    /// the same screen visit doesn't re-freeze the wall reference (and its now-possibly-different
    /// camera angle) out from under an already-recorded clip.
    @State private var hasCapturedWallReference = false

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
                Text("Point at the Wall").font(.headline)
                readinessGuidance
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

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stopRecording { url in
                    recordedURL = url
                }
            } else {
                if !hasCapturedWallReference {
                    // The wall structure is saved AT THIS MOMENT — right as recording actually
                    // starts, from whatever angle the coach is currently standing at. See
                    // `hasCapturedWallReference`'s doc comment.
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

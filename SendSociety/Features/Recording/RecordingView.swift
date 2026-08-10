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
    let onGenerate: (URL, RecordedFrameStore, TimeInterval) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if let recordedURL {
                PlaybackView(url: recordedURL, frameStore: recorder.frameStore, onGenerate: onGenerate)
            } else {
                ARMeshSceneView(session: arManager.session)
                    .ignoresSafeArea()
                controls
            }
        }
        .onAppear {
            arManager.onFrameUpdate = { [weak recorder] frame in
                recorder?.append(frame)
            }
        }
        .onDisappear {
            arManager.onFrameUpdate = nil
        }
    }

    private var controls: some View {
        VStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Step 3 — Record the Climb").font(.headline)
                Text("Same continuous AR session — camera transform and depth are captured alongside the video.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()

            Spacer()

            recordButton
                .padding(.bottom, 40)
        }
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stopRecording { url in
                    recordedURL = url
                }
            } else {
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

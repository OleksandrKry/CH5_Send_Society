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


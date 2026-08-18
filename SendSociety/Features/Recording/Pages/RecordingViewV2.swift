//
//  RecordingViewV2.swift
//  SendSociety
//
//  Created by Christofer Theodore on 14/08/26.
//

import SwiftUI

struct RecordingViewV2: View {
    @ObservedObject var arManager: ARSessionManager
    @ObservedObject var recorder: VideoRecorderEngine
    @Binding var recordedURL: URL?
    let recordingSession: RecordingSessionV2?
    let sessionController: SessionStoreV2?
    let onSessionDone: () -> Void   // NEW

    @StateObject private var engine: RecordingEngineV2

    init(arManager: ARSessionManager, recorder: VideoRecorderEngine, recordedURL: Binding<URL?>, recordingSession: RecordingSessionV2?, sessionController: SessionStoreV2?, onSessionDone: @escaping () -> Void) {
        self.arManager = arManager
        self.recorder = recorder
        self._recordedURL = recordedURL
        self.recordingSession = recordingSession
        self.sessionController = sessionController
        self.onSessionDone = onSessionDone
        _engine = StateObject(wrappedValue: RecordingEngineV2(arManager: arManager, recorder: recorder))
    }
    var body: some View {
        ZStack {
            recordingCameraArea
                .blur(radius: videoAttempt != nil ? 20 : 0)
                .allowsHitTesting(videoAttempt == nil)
                .animation(.easeInOut(duration: 0.25), value: videoAttempt == nil)

            recordingThumbnailArea

            if let videoAttempt, let sessionController {
                PlaybackLayerV2(
                    arManager: arManager,
                    videoURL: sessionController.videoURL(for: videoAttempt),
                    videoAttempt: videoAttempt,
                    frameStore: recorder.frameStore,
                    recordingSession: recordingSession,
                    sessionController: sessionController,
                    onDismiss: { self.videoAttempt = nil }
                )
                .id(videoAttempt.id)
                .padding(.bottom, 220)
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .onAppear {
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
        .onChange(of: videoAttempt?.id) { oldValue, newValue in
            if oldValue == nil, newValue != nil {
                arManager.pause()
            } else if oldValue != nil, newValue == nil {
                engine.resumeAfterPause()
            }
        }
//        testing if fullscreen
//        .fullScreenCover(item: $reviewingAttempt) { attempt in
//            if let sessionController {
//                PlaybackLayerV2(
//                    videoURL: sessionController.videoURL(for: attempt),
//                    frameStore: recorder.frameStore
//                )
//            }
//        }
    }

    private var recordingCameraArea: some View {
        ZStack {
            // MARK: Background
            Color(AppColor.TertiaryDark)
                .ignoresSafeArea()
            ARMeshSceneView(session: arManager.session, showMesh: false)
                .ignoresSafeArea()

            // MARK: Recording Timer
            VStack(spacing: 8) {
                Text("00:00:00")
                    .font(.title2)
                    .monospacedDigit()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: Capsule())

                if let guidanceMessage {
                    Text(guidanceMessage)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: Capsule())
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 16)

            // MARK: Left Control
            HStack {
                Button {
                    // Person / subject action
                } label: {
                    Image(systemName: "person")
                        .font(.title3)
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())

                Spacer()
            }
            .padding(.horizontal, 44)

            // MARK: Right Controls
            VStack(spacing: 16) {
                Button {
                    // Resolution
                } label: {
                    VStack(spacing: 0) {
                        Text("HD").font(.body)
                        Text("RES").font(.caption2)
                    }
                    .frame(width: 56, height: 56)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())

                Button {
                    // Frame rate
                } label: {
                    VStack(spacing: 0) {
                        Text("30").font(.body)
                        Text("FPS").font(.caption2)
                    }
                    .frame(width: 56, height: 56)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())

                Button {
                    // Audio
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title3)
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())

                Button {
                    toggleRecording()
                } label: {
                    RoundedRectangle(cornerRadius: recorder.isRecording ? 8 : 32)
                        .fill(.red)
                        .frame(
                            width: recorder.isRecording ? 32 : 64,
                            height: recorder.isRecording ? 32 : 64
                        )
                        .frame(width: 72, height: 72)
                        .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())
                .disabled(recordButtonIsDisabled)
                .opacity(recordButtonIsDisabled ? 0.4 : 1)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 48)

            // MARK: Close
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button("End Session") {
                        onSessionDone()
                        // Close recording
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.trailing, 48)
            .padding(.bottom, 32)
        }
    }

    private var recordingThumbnailArea: some View {
        VStack {
            Spacer()
            RecordingThumbnail(videoAttempts: recordingSession?.videoAttempts ?? [], selectedAttempt: $videoAttempt, sessionController: sessionController)
        }
        .padding(.bottom, 20)
        .padding(.trailing, 200)
    }
    private var recordButtonIsDisabled: Bool {
        !recorder.isRecording && arManager.isRunning && !engine.isReadyToRecord
    }
    
    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stopRecording { url in
                recordedURL = url
            }
//            arManager.pause()
        } else if !arManager.isRunning {
            engine.resumeAfterPause()
        } else {
            engine.attemptWallMeshSave()
            engine.markRecordingStarted()
            recorder.startRecording()
        }
    }
    private var guidanceMessage: String? {
        if recorder.isRecording {
            return "Recording…"
        }
        if engine.relocalizationTimedOut {
            return "Lost tracking — please rescan the wall"
        }
        if !arManager.isRunning {
            return "Tap Record to resume"
        }
        if let trackingMessage = arManager.trackingQuality.message {
            return trackingMessage
        }
        let quality = engine.depthQuality ?? 0
        if engine.depthQuality == nil {
            return "Point the camera at the wall to begin"
        } else if quality < 0.5 {
            return "Move closer to the wall"
        } else if quality < RecordingEngineV2.readyToRecordDepthThreshold {
            return "Almost there — hold steady"
        } else {
            return "Ready — tap Record"
        }
    }
    private var latestVideoAttempt: VideoAttemptV2? {
        recordingSession?.videoAttempts.last
    }

    @State private var videoAttempt: VideoAttemptV2?
}

#Preview {
    RecordingViewV2(
        arManager: ARSessionManager(),
        recorder: VideoRecorderEngine(),
        recordedURL: .constant(nil),
        recordingSession: nil,
        sessionController: nil,
        onSessionDone: {}
    )
}

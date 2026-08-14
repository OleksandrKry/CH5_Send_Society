//
//  PlaybackViewV2.swift
//  SendSociety
//
//  Created by Christofer Theodore on 14/08/26.
//

import SwiftUI
import AVKit

struct PlaybackViewV2: View {
    
    // Theo start merge
    // MARK: - Given to this screen from outside

    let videoURL: URL
    let frameStore: RecordedFrameStore
    let session: RecordingSession?
    let sessionStore: SessionStore?
    let onGenerate: (URL, RecordedFrameStore, TimeInterval) -> Void
    
//    @State private var currentTime: Double = 30
//    @State private var duration: Double = 75
//    @State private var isPlaying = false
    @State private var playbackRate: Double = 1
    
    // MARK: - The "brains" this screen talks to

    @StateObject private var videoModel: PlaybackModel
    private let engine: PlaybackEngine
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Drawing overlay state

    /// Holds whatever pen/line/angle marks are currently shown over the paused video frame.
    @StateObject private var annotationState = AnnotationState()
    /// The video timestamp `drawingState` currently belongs to.
    @State private var currentDrawingVideoTime: Double = 0
    @State private var isUserDrawing: Bool = false

    init(url: URL, frameStore: RecordedFrameStore, session: RecordingSession?, sessionStore: SessionStore?, onGenerate: @escaping (URL, RecordedFrameStore, TimeInterval) -> Void) {
        self.videoURL = url
        self.frameStore = frameStore
        self.session = session
        self.sessionStore = sessionStore
        self.onGenerate = onGenerate
        _videoModel = StateObject(wrappedValue: PlaybackModel(url: url))
        engine = PlaybackEngine(session: session, sessionStore: sessionStore)
    }
    
    // MARK: - Bindings that connect the UI to the real video player

    private var videoCurrentTime: Binding<Double> {
        Binding(
            get: { videoModel.currentTime },
            set: { videoCurrentTime in videoModel.seek(to: videoCurrentTime) }
        )
    }

    private var videoIsPlaying: Binding<Bool> {
        Binding(
            get: { videoModel.isPlaying },
            set: { videoIsPlayingState in videoIsPlayingState ? videoModel.play() : videoModel.pause() }
        )
    }
    
    private func refreshDrawingForCurrentVideoTime() {
        currentDrawingVideoTime = videoModel.currentTime
        annotationState.load(strokes: engine.findDrawing(nearVideoTime: videoModel.currentTime))
    }
    
    private var getVideoMarkerList: [VideoMarkerModel] {
        engine.getVideoMarkerList()
    }
    
    private func goToVideoMarker(_ videoMarkerModel: VideoMarkerModel) {
            videoModel.seek(to: videoMarkerModel.videoTimeInSeconds)
            currentDrawingVideoTime = videoMarkerModel.videoTimeInSeconds
            annotationState.load(strokes: engine.findDrawing(nearVideoTime: videoMarkerModel.videoTimeInSeconds))
            if videoMarkerModel.has3DPose {
                onGenerate(videoURL, frameStore, videoMarkerModel.videoTimeInSeconds)
            }
        }
    
    var body: some View {
        NavigationStack {
            
            ZStack (alignment: .topLeading) {

                VideoPlayer(player: videoModel.player)
                    .ignoresSafeArea()
                if isUserDrawing {
                    AnnotationComponent(annotationState: annotationState)
                } else if !videoModel.isPlaying, !annotationState.strokes.isEmpty {
                    AnnotationComponent(annotationState: annotationState, isInteractive: false)
                }
                ClimbInfoCard()
                    .padding(.top, 16)
                    .padding(.leading, 16)
            }
            .overlay(alignment: .topTrailing) {
                AnnotateToolbar(annotationState: annotationState, isUserDrawing: $isUserDrawing)
                .padding(.top, 120)
                .padding(.trailing, 24)
            }
            
            .overlay(alignment: .bottom) {
                   PlaybackOverlay(
                        currentTime: videoCurrentTime,
                       duration: videoModel.duration,
                       isPlaying: videoIsPlaying,
                       playbackRate: $playbackRate,
                        videoMarkerList: getVideoMarkerList,
                        onVideoMarkerClick: goToVideoMarker,
                        onGenerate3D: { onGenerate(videoURL, frameStore, videoModel.currentTime) }
                   )
            }
            
            .navigationTitle("Climb at Bali Boulder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                        
                // LEFT
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        // Close action
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                
                
                // RIGHT
                ToolbarItemGroup(placement: .topBarTrailing) {
                    
//                    Button {
//                        // Accessibility action
//                    } label: {
//                        Image(systemName: "figure")
//                    }
                    
                    Button {
                        // More action
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    
//                    Button {
//                        // Share action
//                    } label: {
//                        Image(systemName: "square.and.arrow.up")
//                    }
                }
            }
            .onAppear(perform: refreshDrawingForCurrentVideoTime)
            .onChange(of: videoModel.isPlaying) { _, isPlaying in
                if !isPlaying {
                    refreshDrawingForCurrentVideoTime()
                }
            }
            .onChange(of: videoModel.currentTime) { _, _ in
                if !videoModel.isPlaying {
                    refreshDrawingForCurrentVideoTime()
                }
            }
            .onChange(of: annotationState.strokes) { _, newStrokes in
                engine.saveDrawing(newStrokes, atVideoTime: currentDrawingVideoTime)
            }
        }
    }
    
    
}

#Preview {
    PlaybackViewV2(
        url: FileManager.default.temporaryDirectory.appendingPathComponent("preview.mp4"),
        frameStore: RecordedFrameStore(),
        session: nil,
        sessionStore: nil
    ) { _, _, _ in }
}

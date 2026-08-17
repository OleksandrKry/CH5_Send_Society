//
//  PlaybackLayerV2.swift
//  SendSociety
//
//  Created by Christofer Theodore on 15/08/26.
//

import SwiftUI

/// The overlay that appears on top of RecordingViewV2 when the coach taps a recorded video to
/// review it. Right now this is deliberately just a thin wrapper around PlaybackViewV2 — no
/// annotation persistence yet (session/sessionStore aren't wired to VideoAttemptV2 yet, so
/// passing nil is safe — PlaybackView already treats a nil session as "markers unavailable"),
/// and no 3D-generation toggle yet. This file is where both of those get added later; today it
/// just proves the "layer sits on top of RecordingViewV2" mechanism works.
struct PlaybackLayerV2: View {
    let arManager: ARSessionManager
    let videoURL: URL
    let videoAttempt: VideoAttemptV2
    let frameStore: ARFrameStore
    let recordingSession: RecordingSessionV2?
    let sessionController: SessionStoreV2?
    let onDismiss: () -> Void

    /// nil = showing the video (PlaybackViewV2). Non-nil = showing the 3D view for this result.
    @State private var result: Video3DLidar?
    @State private var currentJointOverrides: [BodyJointName: SIMD3<Float>]?
    @State private var currentAnnotationStrokes: [AnnotationStrokeModel] = []
    @State private var videoAnnotations: [VideoAnnotationEntry] = []
    @State private var savedReconstructions: [Video3DLidarSkeleton] = []
    @State private var lastPlaybackTimestamp: Double = 0
    
    @State private var pendingTimestampSeconds: Double?
    @State private var pendingBaseWorldPositions: [BodyJointName: SIMD3<Float>]?

    var body: some View {
        Group {
            if let result {
                Skeleton3DView(
                    wallAnchors: arManager.wallMeshSnapshot,
                    wallTextureReference: arManager.wallTextureReference,
                    appleVisionSkeleton: result.appleVisionSkeleton,
                    cameraTransform: result.cameraTransform,
                    depthContext: result.depthContext,
                    poseError: result.poseError,
                    onBack: { self.result = nil },
                    onFinished: { self.result = nil },
                    onDelete: deleteCurrentReconstruction,
                    initialAnnotationStrokes: result.initialAnnotationStrokes,
                    onAnnotationStrokesChanged: { strokes in
                        currentAnnotationStrokes = strokes
                        saveCurrentReconstruction()
                    },
                    originalAppleVisionJoints: result.originalAppleVisionJoints,
                    modifiedAppleVisionJoints: result.modifiedAppleVisionJoints,
                    onModifiedAppleVisionJoints: { overrides in
                        currentJointOverrides = overrides
                        saveCurrentReconstruction()
                    }
                )
            } else {
                PlaybackViewV2(
                    url: videoURL,
                    frameStore: frameStore,
                    recordingSession: recordingSession,
                    sessionController: sessionController,
                    initialVideoAnnotations: videoAnnotations,
                    initialReconstructions: savedReconstructions,
                    initialPlaybackTimestamp: lastPlaybackTimestamp,
                    onDismiss: onDismiss,
                    onVideoAnnotationsChanged: { timestamp, strokes in
                        saveVideoAnnotation(timestampSeconds: timestamp, strokes: strokes)
                    }
                ) { url, frameStore, timestampSeconds in
                    generateOrLoad(atTimestamp: timestampSeconds)
                }
            }
        }
        .onAppear {
            videoAnnotations = videoAttempt.videoAnnotations
            savedReconstructions = videoAttempt.video3DLidarSkeletons
        }
    }
    
    private func generateOrLoad(atTimestamp timestampSeconds: Double) {
        
        lastPlaybackTimestamp = timestampSeconds
        
        let nearestFrame = frameStore.nearestFrame(toPlaybackSeconds: timestampSeconds, clipStartTimestamp: videoAttempt.clipStartTimestamp)
        let deviceOrientation = nearestFrame?.deviceOrientation
            ?? UIDeviceOrientation(rawValue: videoAttempt.recordingDeviceOrientationRawValue)
            ?? .portrait
        DebugLog.reconstruction.info("generateOrLoad: deviceOrientation = \(String(describing: deviceOrientation), privacy: .public), source = \(nearestFrame != nil ? "nearestFrame" : "videoAttempt fallback", privacy: .public)")
        
        let input = Video3DLidarInput(videoURL: videoURL, frameStore: frameStore, timestampSeconds: timestampSeconds, clipStartTimestamp: videoAttempt.clipStartTimestamp)
        let newResult = Generate3DEngine.loadOrGenerate(input: input, video3DLidarSkeletons: savedReconstructions, wallReference: arManager.wallTextureReference)
        result = newResult
        pendingTimestampSeconds = newResult.timestampSeconds
        pendingBaseWorldPositions = newResult.baseWorldPositions
        currentJointOverrides = newResult.modifiedAppleVisionJoints
        currentAnnotationStrokes = newResult.initialAnnotationStrokes

        if !newResult.wasLoadedFromSavedEntry, newResult.originalAppleVisionJoints != nil {
            saveCurrentReconstruction()
        }
    }

    private func saveCurrentReconstruction() {
        guard let result else { return }
        Generate3DEngine.save(
            recordingSession: recordingSession,
            sessionController: sessionController,
            videoAttemptID: videoAttempt.id,
            timestampSeconds: result.timestampSeconds,
            baseWorldPositions: result.baseWorldPositions,
            jointOverrides: currentJointOverrides,
            annotationStrokes: currentAnnotationStrokes,
            isApproximate: true
        )
        if let recordingSession, let updated = recordingSession.videoAttempt(id: videoAttempt.id) {
            savedReconstructions = updated.video3DLidarSkeletons
            
            
        }
    }
    private func saveVideoAnnotation(timestampSeconds: Double, strokes: [AnnotationStrokeModel]) {
        guard let recordingSession, let sessionController,
              var attempt = recordingSession.videoAttempt(id: videoAttempt.id) else { return }
        attempt.setVideoAnnotation(timestampSeconds: timestampSeconds, strokes: strokes)
        sessionController.save(attempt, in: recordingSession)
        videoAnnotations = attempt.videoAnnotations
    }
    private func deleteCurrentReconstruction() {
        guard let result,
              let recordingSession,
              let sessionController,
              var attempt = recordingSession.videoAttempt(id: videoAttempt.id),
              let match = savedReconstructions.first(where: {
                  abs($0.timestampSeconds - result.timestampSeconds) <= 0.3 // mirrors Generate3DEngine's match window
              })
        else { return }

        attempt.removeSkeleton(id: match.id)
        sessionController.save(attempt, in: recordingSession)
        savedReconstructions = attempt.video3DLidarSkeletons
        self.result = nil
        currentJointOverrides = nil
        currentAnnotationStrokes = []
    }
}

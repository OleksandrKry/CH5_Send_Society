//
//  OfflinePlaybackLayer.swift
//  SendSociety
//
//  Created by Christofer Theodore on 16/08/26.
//

import SwiftUI
import ARKit

/// Offline counterpart to `PlaybackLayerV2` — opened from the Library for a video with no live
/// AR session behind it anymore. Toggles between `OfflinePlaybackView` (2D) and `Skeleton3DView`
/// (3D) exactly like `PlaybackLayerV2` does. The only real difference: when a moment has no saved
/// reconstruction yet, this falls back to `AppleVisionEstimator`'s no-depth Vision estimate
/// instead of a live LiDAR generation, since there's no `frameStore`/`arManager` here.
struct OfflinePlaybackLayer: View {
    let videoURL: URL
    let videoAttempt: VideoAttemptV2
    let recordingSession: RecordingSessionV2
    let sessionController: SessionStoreV2
    let onDismiss: () -> Void

    @State private var result: Video3DLidar?
    @State private var currentIsApproximate = false
    @State private var currentJointOverrides: [BodyJointName: SIMD3<Float>]?
    @State private var currentAnnotationStrokes: [AnnotationStrokeModel] = []
    @State private var videoAnnotations: [VideoAnnotationEntry] = []
    @State private var savedReconstructions: [Video3DLidarSkeleton] = []
    @State private var lastPlaybackTimestamp: Double = 0
    @State private var wallTextureReference: ARSessionManager.WallTextureReference?
    @State private var isEstimating = false
    @State private var estimateErrorMessage: String?

    /// Mirrors `Generate3DEngine.loadOrGenerate`'s own matching tolerance.
    private let savedEntryMatchWindowSeconds: Double = 0.3

    var body: some View {
        Group {
            if let result {
                Skeleton3DView(
                    wallAnchors: [],
                    wallTextureReference: wallTextureReference,
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
                    },
                    isApproximate: currentIsApproximate
                )
            } else {
                OfflinePlaybackView(
                    url: videoURL,
                    videoAttempt: videoAttempt,
                    recordingSession: recordingSession,
                    sessionController: sessionController,
                    initialVideoAnnotations: videoAnnotations,
                    initialReconstructions: savedReconstructions,
                    initialPlaybackTimestamp: lastPlaybackTimestamp,
                    onDismiss: onDismiss,
                    onVideoAnnotationsChanged: saveVideoAnnotation,
                    onGenerate: { url, timestamp in generateOrLoad(atTimestamp: timestamp) }
                )
            }
        }
        .onAppear {
            videoAnnotations = videoAttempt.videoAnnotations
            savedReconstructions = videoAttempt.video3DLidarSkeletons
            wallTextureReference = sessionController.wallTextureReference(for: recordingSession)
        }
        .overlay {
            if isEstimating {
                ProgressView("Estimating pose…")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func generateOrLoad(atTimestamp timestampSeconds: Double) {
        lastPlaybackTimestamp = timestampSeconds
        estimateErrorMessage = nil

        if let matched = savedReconstructions.first(where: {
            abs($0.timestampSeconds - timestampSeconds) <= savedEntryMatchWindowSeconds
        }) {
            applyLoadedEntry(matched)
            return
        }

        isEstimating = true
        let deviceOrientation = UIDeviceOrientation(rawValue: videoAttempt.recordingDeviceOrientationRawValue) ?? .portrait
        let url = videoURL
        let reference = wallTextureReference

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let estimated = try AppleVisionEstimator.estimate(
                    videoURL: url,
                    atSeconds: timestampSeconds,
                    deviceOrientation: deviceOrientation,
                    wallReference: reference
                )
                DispatchQueue.main.async {
                    isEstimating = false
                    applyFreshEstimate(estimated)
                }
            } catch {
                DispatchQueue.main.async {
                    isEstimating = false
                    estimateErrorMessage = "Couldn't read a frame from the video at this moment."
                }
            }
        }
    }

    private func applyLoadedEntry(_ entry: Video3DLidarSkeleton) {
        result = Video3DLidar(
            timestampSeconds: entry.timestampSeconds,
            baseWorldPositions: entry.originalAppleVisionJoints,
            originalAppleVisionJoints: entry.originalAppleVisionJoints,
            modifiedAppleVisionJoints: entry.modifiedAppleVisionJoints,
            initialAnnotationStrokes: entry.annotationStrokes,
            appleVisionSkeleton: nil,
            cameraTransform: nil,
            depthContext: nil,
            poseError: nil,
            wasLoadedFromSavedEntry: true
        )
        currentJointOverrides = entry.modifiedAppleVisionJoints
        currentAnnotationStrokes = entry.annotationStrokes
        currentIsApproximate = entry.isApproximate
    }

    private func applyFreshEstimate(_ entry: Video3DLidarSkeleton) {
        result = Video3DLidar(
            timestampSeconds: entry.timestampSeconds,
            baseWorldPositions: entry.originalAppleVisionJoints,
            originalAppleVisionJoints: entry.originalAppleVisionJoints,
            modifiedAppleVisionJoints: nil,
            initialAnnotationStrokes: [],
            appleVisionSkeleton: nil,
            cameraTransform: nil,
            depthContext: nil,
            poseError: nil,
            wasLoadedFromSavedEntry: false
        )
        currentJointOverrides = nil
        currentAnnotationStrokes = []
        currentIsApproximate = true
        saveCurrentReconstruction() // persist the estimate so it's found (not re-estimated) next time
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
            isApproximate: currentIsApproximate
        )
        if let updated = recordingSession.videoAttempt(id: videoAttempt.id) {
            savedReconstructions = updated.video3DLidarSkeletons
        }
    }

    private func saveVideoAnnotation(timestampSeconds: Double, strokes: [AnnotationStrokeModel]) {
        guard var attempt = recordingSession.videoAttempt(id: videoAttempt.id) else { return }
        attempt.setVideoAnnotation(timestampSeconds: timestampSeconds, strokes: strokes)
        sessionController.save(attempt, in: recordingSession)
        videoAnnotations = attempt.videoAnnotations
    }
    
    private func deleteCurrentReconstruction() {
        guard let result,
              let match = savedReconstructions.first(where: {
                  abs($0.timestampSeconds - result.timestampSeconds) <= savedEntryMatchWindowSeconds
              })
        else { return }
        guard var attempt = recordingSession.videoAttempt(id: videoAttempt.id) else { return }
        attempt.removeSkeleton(id: match.id)
        sessionController.save(attempt, in: recordingSession)
        savedReconstructions = attempt.video3DLidarSkeletons
        self.result = nil
        currentJointOverrides = nil
        currentAnnotationStrokes = []
        currentIsApproximate = false
    }
}

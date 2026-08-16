import Foundation
import ARKit
import simd

@MainActor
enum Generate3DEngine {
    static let savedEntryMatchWindowSeconds: Double = 0.3

    /// load specific 3d or generate new 3d
    static func loadOrGenerate(
        input: Video3DLidarInput,
        video3DLidarSkeletons: [Video3DLidarSkeleton],
        wallReference: ARSessionManager.WallTextureReference?
    ) -> Video3DLidar {
        DebugLog.reconstruction.info("loadOrGenerate: requested t=\(input.timestampSeconds, privacy: .public), saved entries=\(video3DLidarSkeletons.map { $0.timestampSeconds }, privacy: .public)")

        if let existing = video3DLidarSkeletons.first(where: { abs($0.timestampSeconds - input.timestampSeconds) <= savedEntryMatchWindowSeconds }) {
            let nearestFrame = input.frameStore.nearestFrame(toPlaybackSeconds: existing.timestampSeconds, clipStartTimestamp: input.clipStartTimestamp)
                
            DebugLog.reconstruction.info("MATCHED saved entry t=\(existing.timestampSeconds, privacy: .public) — hasModifiedJoints=\(existing.modifiedAppleVisionJoints != nil, privacy: .public), strokeCount=\(existing.annotationStrokes.count, privacy: .public)")
                    
            DebugLog.reconstruction.info("Loaded saved reconstruction for t=\(existing.timestampSeconds, privacy: .public)s — skipping Vision")
            return Video3DLidar(
                timestampSeconds: existing.timestampSeconds,
                baseWorldPositions: existing.originalAppleVisionJoints,
                originalAppleVisionJoints: existing.originalAppleVisionJoints,
                modifiedAppleVisionJoints: existing.modifiedAppleVisionJoints,
                initialAnnotationStrokes: existing.annotationStrokes,
                appleVisionSkeleton: nil,
                cameraTransform: nearestFrame?.cameraTransform,
                depthContext: nil,
                poseError: nil,
                wasLoadedFromSavedEntry: true
            )
        }

        do {
            let generated = try Video3DLidarGenerator.generate(input: input, wallReference: wallReference)
            return Video3DLidar(
                timestampSeconds: input.timestampSeconds,
                baseWorldPositions: generated.appleVisionJoints ?? [:],
                originalAppleVisionJoints: generated.appleVisionJoints,
                modifiedAppleVisionJoints: nil,
                initialAnnotationStrokes: [],
                appleVisionSkeleton: generated.appleVisionSkeleton,
                cameraTransform: generated.cameraTransform,
                depthContext: generated.depthContext,
                poseError: generated.poseError,
                wasLoadedFromSavedEntry: false
            )
        } catch Video3DLidarGenerator.GenerationError.noStoredFrameData {
            return failedResult(atVideoTime: input.timestampSeconds, message: "No stored depth/camera data for this moment in the video.")
        } catch Video3DLidarGenerator.GenerationError.couldNotReadFrame {
            return failedResult(atVideoTime: input.timestampSeconds, message: "Couldn't read this frame from the recording — try a different moment in the video.")
        } catch {
            let description = String(describing: error)
            DebugLog.reconstruction.error("LiveReconstructionGenerator.generate threw an unexpected error: \(description, privacy: .public)")
            return failedResult(atVideoTime: input.timestampSeconds, message: "Something went wrong generating this reconstruction — try a different moment in the video.")
        }
    }

    private static func failedResult(atVideoTime videoTimeInSeconds: Double, message: String) -> Video3DLidar {
        Video3DLidar(
            timestampSeconds: videoTimeInSeconds,
            baseWorldPositions: [:],
            originalAppleVisionJoints: nil,
            modifiedAppleVisionJoints: nil,
            initialAnnotationStrokes: [],
            appleVisionSkeleton: nil,
            cameraTransform: nil,
            depthContext: nil,
            poseError: message,
            wasLoadedFromSavedEntry: false
        )
    }

    /// Writes the current in-memory reconstruction state back into the SPECIFIC video attempt it
    /// belongs to (identified by videoAttemptID), inside session. No-op if anything needed is nil.
    static func save(
        recordingSession: RecordingSessionV2?,
        sessionController: SessionStoreV2?,
        videoAttemptID: UUID?,
        timestampSeconds: Double,
        baseWorldPositions: [BodyJointName: SIMD3<Float>],
        jointOverrides: [BodyJointName: SIMD3<Float>]?,
        annotationStrokes: [AnnotationStrokeModel],
        isApproximate: Bool
    ) {
        guard let recordingSession, let sessionController, let videoAttemptID,
              var attempt = recordingSession.videoAttempt(id: videoAttemptID) else { return }
        let entry = Video3DLidarSkeleton(
            timestampSeconds: timestampSeconds,
            originalAppleVisionJoints: baseWorldPositions,
            modifiedAppleVisionJoints: jointOverrides,
            annotationStrokes: annotationStrokes,
            isApproximate: isApproximate
        )
        attempt.upsertSkeleton(entry)
        sessionController.save(attempt, in: recordingSession)
        
    }
}

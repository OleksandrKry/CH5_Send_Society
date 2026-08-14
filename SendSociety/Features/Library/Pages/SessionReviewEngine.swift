import Foundation
import CoreGraphics
import UIKit

/// One "Preview Skeleton" result — the exact raw video frame that was analyzed, plus whatever 2D
/// joint points Vision found in it. An EMPTY `points` dictionary is a valid, honest result (it
/// means "no person in this frame"), not an error.
struct SkeletonPreviewResult {
    let image: CGImage
    let points: [BodyJointName: CGPoint]
    let videoTimeInSeconds: Double
}

/// A plain, human-readable "here's what went wrong" message for `generateSkeletonPreview(...)`.
/// Swift's `Result` type requires its failure case to conform to `Error` — a bare `String` does
/// NOT conform to `Error` on its own, so this tiny wrapper exists purely to satisfy that
/// requirement. Read `.message` directly wherever this shows up (e.g.
/// `SessionReviewView.skeletonPreviewErrorMessage`).
struct SkeletonPreviewFailure: Error {
    let message: String
}

/// SessionReviewEngine is the "brain" behind revisiting a saved session from the Library. It does
/// NOT import SwiftUI — it only knows how to:
///   1. Find (and delete) the saved 3D pose closest to a given video moment.
///   2. Generate a NEW 3D pose estimate for a moment that doesn't have one yet.
///   3. Run a quick, disposable "Preview Skeleton" detection for sanity-checking a moment before
///      committing to a real Estimate.
///
/// Saved-drawing lookup and the scrubber's marker list are handled by `PlaybackEngine` (see
/// Features/Recording/Pages/PlaybackEngine.swift) — this screen reuses that SAME engine instead
/// of duplicating its logic, since "find/save a drawing" and "build the marker list" work
/// identically here as they do on the just-recorded review screen.
///
/// `@MainActor` because `deleteReconstruction(_:)` calls `SessionStore.save()` directly, and the
/// completion handlers of `generateEstimate`/`generateSkeletonPreview` do the same after hopping
/// back to the main queue — `SessionStore` is itself `@MainActor`-isolated (SwiftData's
/// `ModelContext` isn't safe to touch off the main thread). This engine is only ever created and
/// called from a View anyway (already on the main thread), so this just tells the compiler what
/// was already true. The actual Vision/frame-extraction work in `generateEstimate`/
/// `generateSkeletonPreview` still runs on a background queue exactly as before — marking the
/// class `@MainActor` only affects where its methods can be CALLED FROM, not what thread the
/// `DispatchQueue.global(...).async { ... }` blocks inside them run on.
@MainActor
final class SessionReviewEngine {
    /// How close (in seconds) the video needs to be to a saved 3D pose before that pose counts
    /// as "the one for this exact moment" (drives the "View 3D Reconstruction" button).
    static let nearbyReconstructionWindowSeconds: Double = 0.3
    /// A "Preview Skeleton" result younger than this (in seconds of video-time difference from
    /// the current position) is treated as "already showing this moment" — skips a redundant,
    /// slow re-detection.
    static let skeletonPreviewRefreshThresholdSeconds: Double = 0.05

    private let session: RecordingSession
    private let sessionStore: SessionStore

    init(session: RecordingSession, sessionStore: SessionStore) {
        self.session = session
        self.sessionStore = sessionStore
    }

    /// The saved 3D pose closest to `videoTimeInSeconds`, if one exists within
    /// `nearbyReconstructionWindowSeconds`.
    func reconstruction(nearVideoTime videoTimeInSeconds: Double) -> ReconstructionEntry? {
        session.reconstructions.first { abs($0.timestampSeconds - videoTimeInSeconds) <= Self.nearbyReconstructionWindowSeconds }
    }

    /// Permanently deletes a saved 3D pose so the coach can generate a fresh one for that moment.
    func deleteReconstruction(_ entry: ReconstructionEntry) {
        session.removeReconstruction(id: entry.id)
        sessionStore.save()
    }

    /// Pulls the video frame at `videoTimeInSeconds` and runs Vision on it fresh to build a REAL,
    /// saved 3D pose estimate (flagged `isApproximate`, since there's no live LiDAR depth to
    /// ground it in — see `SessionReviewView`'s top doc comment for the full explanation of why
    /// this is lower-fidelity than a live Step 4 generation). Runs off the main thread; always
    /// calls `completion` back on the main thread.
    func generateEstimate(
        videoURL: URL,
        atVideoTime videoTimeInSeconds: Double,
        wallTextureReference: ARSessionManager.WallTextureReference?,
        deviceOrientation: UIDeviceOrientation,
        completion: @escaping (Result<ReconstructionEntry, Error>) -> Void
    ) {
        let session = self.session
        let sessionStore = self.sessionStore
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entry = try ReconstructionEstimator.estimate(
                    videoURL: videoURL,
                    atSeconds: videoTimeInSeconds,
                    deviceOrientation: deviceOrientation,
                    wallReference: wallTextureReference
                )
                DispatchQueue.main.async {
                    session.upsertReconstruction(entry)
                    sessionStore.save()
                    completion(.success(entry))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Pulls the video frame at `videoTimeInSeconds` and runs Vision on it fresh, purely to draw
    /// a 2D skeleton overlay for a sanity check — nothing here is saved, unlike
    /// `generateEstimate(...)`. Runs off the main thread; always calls `completion` back on the
    /// main thread.
    func generateSkeletonPreview(
        videoURL: URL,
        atVideoTime videoTimeInSeconds: Double,
        wallTextureReference: ARSessionManager.WallTextureReference,
        deviceOrientation: UIDeviceOrientation,
        completion: @escaping (Result<SkeletonPreviewResult, SkeletonPreviewFailure>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = VideoFrameExtractor.extractFrame(from: videoURL, atSeconds: videoTimeInSeconds) else {
                DispatchQueue.main.async {
                    completion(.failure(SkeletonPreviewFailure(message: "Couldn't read a frame from the video at this moment.")))
                }
                return
            }

            var points: [BodyJointName: CGPoint] = [:]
            // Only a genuine "no person in this frame" result is treated as the honest, silent
            // empty-points answer — anything else (model load failure/timeout, etc.) is surfaced
            // as a real error instead of silently reading as "no person detected."
            var detectionErrorMessage: String?
            do {
                let sample = try BodyPose3DExtractor.detect(inVideoFrame: cgImage, deviceOrientation: deviceOrientation)
                points = BodyPose3DExtractor.projected2DImagePoints(
                    from: sample,
                    intrinsics: wallTextureReference.intrinsics,
                    imageResolution: wallTextureReference.imageResolution,
                    deviceOrientation: deviceOrientation
                )
            } catch BodyPoseError.noPersonDetected {
                // Honest empty result — nothing to surface as an error.
            } catch {
                detectionErrorMessage = "Vision detection failed: \(error.localizedDescription)"
            }

            DispatchQueue.main.async {
                if let detectionErrorMessage {
                    completion(.failure(SkeletonPreviewFailure(message: detectionErrorMessage)))
                } else {
                    completion(.success(SkeletonPreviewResult(image: cgImage, points: points, videoTimeInSeconds: videoTimeInSeconds)))
                }
            }
        }
    }
}

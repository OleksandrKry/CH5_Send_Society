//
//  AppleVisionEstimator.swift
//  SendSociety
//
//  Created by Christofer Theodore on 16/08/26.
//

import CoreGraphics
import Foundation
import UIKit
import simd

/// Builds a `Video3DLidarSkeleton` from a saved video frame WITHOUT any live LiDAR depth — the
/// fallback `OfflineReviewLayer` uses for a moment that has no saved reconstruction yet. Renamed
/// from `ReconstructionEstimator` to match the Apple Vision naming cluster.
enum AppleVisionEstimator {
    /// Thrown only when there's no frame at all to analyze — "no climber detected" still produces
    /// a usable wall-only `Video3DLidarSkeleton`, not an error (see `estimate`'s doc comment).
    enum EstimationError: Error {
        case couldNotReadFrame
    }
    /// Own tuned lookup, separate from `AppleVisionSkeletonExtractor.visionOnlyRotationQuarterTurns`
    /// — this corrects a different mismatch (world-placement camera transform, not Vision-camera-
    /// space joints), so don't assume a value that's right there is right here too. Portrait's
    /// value matches the old Estimate-3D-only path's confirmed-on-device correction; every other
    /// case starts from that same value as an untested working hypothesis.
    private static func estimateInitialRotationQuarterTurns(for deviceOrientation: UIDeviceOrientation) -> Int {
        switch deviceOrientation {
        case .portrait: return 1           // CONFIRMED on real device (old Estimate-3D-only path)
        case .portraitUpsideDown: return 1 // untested
        case .landscapeLeft: return 1      // untested
        case .landscapeRight: return 1     // untested
        case .faceUp: return 1
        case .faceDown: return 1
        case .unknown: return 1
        @unknown default: return 1
        }
    }
    static func estimate(
        videoURL: URL,
        atSeconds timestamp: Double,
        deviceOrientation: UIDeviceOrientation,
        wallReference: ARSessionManager.WallTextureReference?
    ) throws -> Video3DLidarSkeleton {
        guard let cgImage = VideoFrameExtractor.extractFrame(from: videoURL, atSeconds: timestamp) else {
            throw EstimationError.couldNotReadFrame
        }

        do {
            let appleVisionSkeleton = try AppleVisionSkeletonExtractor.detect(
                inVideoFrame: cgImage,
                deviceOrientation: deviceOrientation
            )

            let estimateInitialRotation = AppleVisionSkeletonExtractor.zAxisRotation(
                quarterTurns: estimateInitialRotationQuarterTurns(for: deviceOrientation)
            )
            let approximateCameraTransform = (wallReference?.cameraTransform ?? matrix_identity_float4x4) * estimateInitialRotation

            let originalAppleVisionJoints = Video3DRealityKit.generate3DJointPositions(
                from: appleVisionSkeleton,
                cameraTransform: approximateCameraTransform,
                depthContext: nil,
                wallReference: wallReference
            )

            return Video3DLidarSkeleton(
                timestampSeconds: timestamp,
                originalAppleVisionJoints: originalAppleVisionJoints,
                modifiedAppleVisionJoints: nil,
                annotationStrokes: [],
                isApproximate: true
            )
        } catch {
            // No climber detected — still a legitimate wall-only result, not a failure.
            return Video3DLidarSkeleton(
                timestampSeconds: timestamp,
                originalAppleVisionJoints: [:],
                modifiedAppleVisionJoints: nil,
                annotationStrokes: [],
                isApproximate: true
            )
        }
    }
}

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

            // Same fixed 90° correction as the old Estimate-3D-only path — only affects this
            // no-live-depth fallback, never the live-generate or load-saved paths.
            let estimateInitialRotation = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
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

import Vision
import ARKit
import simd
import UIKit

/// Output of a single VNDetectHumanBodyPose3DRequest call. `Codable` (written manually below,
/// rather than `: Codable` + automatic synthesis) so a generated reconstruction can be saved as
/// part of a `RecordingSession` (see `Core/Persistence`).
struct BodyPoseSample {
    /// Joint positions as returned by Vision: translation relative to the skeleton's root
    /// joint (center of the hip), in meters.
    var rootRelativePositions: [BodyJointName: SIMD3<Float>]
    /// Apple: "a transform from the skeleton hip to the camera." Needed to place joints into
    /// ARKit world space — see `worldPosition(rootRelative:cameraOriginMatrix:cameraTransform:)`.
    var cameraOriginMatrix: simd_float4x4
    var bodyHeight: Float
}

/// Manual `Codable` conformance — Swift's automatic synthesis failed to recognize
/// `simd_float4x4`'s `Codable` conformance from `Core/Persistence/CodableSIMD.swift` (a different
/// file in the same target), reported as "does not conform to protocol 'Decodable'" (the same
/// issue hit `WallScanArchive.Metadata`; see that type's doc comment). Writing the keyed
/// container decode/encode out by hand only requires `simd_float4x4.init(from:)`/`encode(to:)` to
/// work for one direct call each, which sidesteps whatever synthesis-visibility quirk that was.
extension BodyPoseSample: Codable {
    private enum CodingKeys: String, CodingKey {
        case rootRelativePositions, cameraOriginMatrix, bodyHeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootRelativePositions = try container.decode([BodyJointName: SIMD3<Float>].self, forKey: .rootRelativePositions)
        cameraOriginMatrix = try container.decode(simd_float4x4.self, forKey: .cameraOriginMatrix)
        bodyHeight = try container.decode(Float.self, forKey: .bodyHeight)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rootRelativePositions, forKey: .rootRelativePositions)
        try container.encode(cameraOriginMatrix, forKey: .cameraOriginMatrix)
        try container.encode(bodyHeight, forKey: .bodyHeight)
    }
}

enum BodyPoseError: Error {
    case noPersonDetected
    case visionRequestFailed(Error)
}

/// Output of `BodyPose3DExtractor.detectHands` — LiDAR-grounded 3D positions for each detected
/// hand's joints, in CAMERA SPACE (convert with `BodyPose3DExtractor.worldPosition(cameraSpace:
/// cameraTransform:)`, same as grounded body joints). Empty dictionaries mean that hand wasn't
/// detected, or none of its joints could get a confident depth reading.
struct HandPoseSample {
    var leftHandJoints: [HandJointName: SIMD3<Float>] = [:]
    var rightHandJoints: [HandJointName: SIMD3<Float>] = [:]
}

/// Manual `Codable` for the same reason as `BodyPoseSample` above — kept consistent even though
/// this one's only simd usage is inside dictionary values, since that still needs
/// `SIMD3<Float>: Decodable` resolvable at the same synthesis point that failed there.
extension HandPoseSample: Codable {
    private enum CodingKeys: String, CodingKey {
        case leftHandJoints, rightHandJoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leftHandJoints = try container.decode([HandJointName: SIMD3<Float>].self, forKey: .leftHandJoints)
        rightHandJoints = try container.decode([HandJointName: SIMD3<Float>].self, forKey: .rightHandJoints)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(leftHandJoints, forKey: .leftHandJoints)
        try container.encode(rightHandJoints, forKey: .rightHandJoints)
    }
}

enum BodyPose3DExtractor {

    private static let jointMap: [(BodyJointName, VNHumanBodyPose3DObservation.JointName)] = [
        (.centerHead, .centerHead), (.topHead, .topHead),
        (.centerShoulder, .centerShoulder), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.spine, .spine), (.root, .root),
        (.leftHip, .leftHip), (.rightHip, .rightHip),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
        (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle),
    ]

    /// Runs VNDetectHumanBodyPose3DRequest on a single camera frame.
    ///
    /// NOTE on depth — read before "fixing" this: we deliberately do NOT thread ARKit's
    /// `ARDepthData` (from `ARFrame.sceneDepth`) into `VNImageRequestHandler`'s `depthData:`
    /// parameter. That parameter expects `AVDepthData`, and there is no stable, documented
    /// conversion from `ARDepthData` (LiDAR scene depth) to `AVDepthData` (camera-capture
    /// depth) — shipping a hand-rolled bridge for that would be unverified guesswork. Instead:
    /// Vision's 3D request produces its own metric-scale estimate from the color image alone,
    /// and we separately combine its output with ARKit's own per-frame depth map + camera
    /// transform for the world-space alignment work in Step 4. This split is a known, flagged
    /// open question to validate on real hardware (see success criterion #4 in the brief).
    /// `deviceOrientation` defaults to the CURRENT device orientation, which is only correct for
    /// LIVE frames (Step 2 calibration, processed the instant they're captured). For a STORED
    /// frame (Step 4, `RecordedFrameData`), the caller MUST pass that frame's own
    /// `deviceOrientation` explicitly — using "current" there would silently use whatever
    /// orientation the device happens to be in NOW, possibly minutes and a full rotation away
    /// from how it was actually held when this specific frame was captured. This exact mismatch
    /// was the root cause of the skeleton coming out rotated relative to the wall in Step 4.
    static func detect(in pixelBuffer: CVPixelBuffer, deviceOrientation: UIDeviceOrientation = UIDevice.current.orientation) throws -> BodyPoseSample {
        try runDetection(handler: VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: cameraOrientation(for: deviceOrientation),
            options: [:]
        ))
    }

    /// Same request, for a `CGImage` pulled out of a SAVED video file (`VideoFrameExtractor`)
    /// rather than a live/stored ARKit pixel buffer — used by session review's "Estimate 3D" (see
    /// `SessionReviewView.generateEstimate`).
    ///
    /// `deviceOrientation` MUST be the same orientation the phone was held in when this recording
    /// was made (`RecordingSession.recordingDeviceOrientationRawValue`, captured once by
    /// `VideoRecorder` at recording start) — NOT a fixed `.up`. `VideoFrameExtractor` deliberately
    /// returns the video's RAW native pixel layout (same as ARKit's `capturedImage`, never
    /// rotated), so this needs the exact same `cameraOrientation(for:)` interpretation
    /// `detect(in:deviceOrientation:)` uses for live frames. Passing a fixed `.up` here (as an
    /// earlier version of this function did, paired with an already-upright extracted image) is
    /// what caused a re-generated reconstruction's posture to come out facing the wrong direction
    /// compared to the SAME clip's live-generated ones: Vision's reported joint axes are relative
    /// to whatever orientation it's TOLD the image is in, and that assumption has to match the
    /// actual pixel layout it's given, exactly like the live path already requires.
    static func detect(inVideoFrame cgImage: CGImage, deviceOrientation: UIDeviceOrientation) throws -> BodyPoseSample {
        try runDetection(handler: VNImageRequestHandler(
            cgImage: cgImage,
            orientation: cameraOrientation(for: deviceOrientation),
            options: [:]
        ))
    }
//    where cg image, change the class to ciimage, where the last image generated from ar session, make it ci image, with depth value

    private static func runDetection(handler: VNImageRequestHandler) throws -> BodyPoseSample {
        let request = VNDetectHumanBodyPose3DRequest()
        do {
            try handler.perform([request])
        } catch {
            throw BodyPoseError.visionRequestFailed(error)
        }
        guard let observation = request.results?.first else {
            throw BodyPoseError.noPersonDetected
        }

        var positions: [BodyJointName: SIMD3<Float>] = [:]
        for (ours, vision) in jointMap {
            guard let point = try? observation.recognizedPoint(vision) else { continue }
            let translation = point.position.columns.3
            positions[ours] = SIMD3<Float>(translation.x, translation.y, translation.z)
        }
//        DebugLog.reconstruction.(positions)
            

        return BodyPoseSample(
            rootRelativePositions: positions,
            cameraOriginMatrix: observation.cameraOriginMatrix,
            bodyHeight: observation.bodyHeight
        )
    }

    /// A source of per-pixel brightness for the bilateral-weighted depth lookup
    /// (`lidarGroundedCameraSpacePosition`'s `nearestConfidentDepth` replacement) — deliberately an
    /// enum rather than a single `CVPixelBuffer` field on `DepthGroundingContext`, because the two
    /// places that can supply a color frame hand it over in genuinely different native formats:
    /// a live/stored ARKit frame's `capturedImage` (bi-planar YCbCr — `.pixelBuffer`), or a
    /// `CGImage` re-extracted from a saved video via `VideoFrameExtractor` for Step 4, which has no
    /// live ARFrame to read from at all (`.cgImage`). See `LockedLuma`/`lockLuma` for how each case
    /// is turned into a plain per-pixel brightness read.
    enum LumaSource {
        case pixelBuffer(CVPixelBuffer)
        case cgImage(CGImage)
    }

    /// Bundles everything needed to ground a Vision joint estimate in real LiDAR depth: the
    /// camera pose/intrinsics for the SAME frame the joint was detected in, plus that frame's
    /// real depth/confidence maps. Built either from a live `ARFrame` (Step 2 calibration) or
    /// from a stored `RecordedFrameData` (Step 4 reconstruction, looking at a past frame).
    struct DepthGroundingContext {
        let cameraTransform: simd_float4x4
        let intrinsics: simd_float3x3
        let imageResolution: CGSize
        let depthMap: CVPixelBuffer
        let confidenceMap: CVPixelBuffer?
        /// Device orientation for the SAME frame this depth data came from — MUST be the same
        /// value passed as `deviceOrientation` to the `detect(in:)` call that produced the
        /// `BodyPoseSample` being grounded against this context, or the bearing-rotation
        /// correction in `lidarGroundedCameraSpacePosition` silently uses the wrong orientation.
        /// See `RecordedFrameData.deviceOrientation`'s doc comment for the full story.
        let deviceOrientation: UIDeviceOrientation
        /// Optional source of per-pixel brightness for bilateral-weighted depth grounding (see
        /// `LumaSource`'s doc comment) — nil means "no color available for this context," in
        /// which case grounding transparently falls back to the older nearest-valid-neighbor
        /// search (`nearestConfidentDepth`) with no behavior change from before this feature
        /// existed. Defaulted to nil here (rather than a required initializer parameter)
        /// specifically so `RecordedFrameStore.swift`'s `RecordedFrameData.depthGroundingContext`
        /// — which, BY DESIGN, has no color image to offer — keeps compiling completely
        /// unchanged; see that type's doc comment for the on-device OOM-crash history that makes
        /// "just store the color image too" a hard constraint, not an oversight. Step 4
        /// (`LiveReconstructionGenerator`) attaches one after the fact via `withLumaSource(_:)`,
        /// reusing the color frame it already re-extracts from the saved video for Vision
        /// detection anyway — no extra decode/storage cost.
        let lumaSource: LumaSource?

        /// Explicit initializer (rather than relying on the synthesized memberwise one) so
        /// `lumaSource` can default to nil at every existing call site — including
        /// `RecordedFrameStore.swift`'s `RecordedFrameData.depthGroundingContext`, which never
        /// passes it at all — without those call sites needing any change.
        init(
            cameraTransform: simd_float4x4,
            intrinsics: simd_float3x3,
            imageResolution: CGSize,
            depthMap: CVPixelBuffer,
            confidenceMap: CVPixelBuffer?,
            deviceOrientation: UIDeviceOrientation,
            lumaSource: LumaSource? = nil
        ) {
            self.cameraTransform = cameraTransform
            self.intrinsics = intrinsics
            self.imageResolution = imageResolution
            self.depthMap = depthMap
            self.confidenceMap = confidenceMap
            self.deviceOrientation = deviceOrientation
            self.lumaSource = lumaSource
        }

        static func from(frame: ARFrame, deviceOrientation: UIDeviceOrientation = UIDevice.current.orientation) -> DepthGroundingContext? {
            guard let sceneDepth = frame.sceneDepth else { return nil }
            return DepthGroundingContext(
                cameraTransform: frame.camera.transform,
                intrinsics: frame.camera.intrinsics,
                imageResolution: frame.camera.imageResolution,
                depthMap: sceneDepth.depthMap,
                confidenceMap: sceneDepth.confidenceMap,
                deviceOrientation: deviceOrientation,
                lumaSource: .pixelBuffer(frame.capturedImage)
            )
        }

        /// Returns a copy of this context with `lumaSource` attached — see `lumaSource`'s doc
        /// comment for why this is a separate step rather than a constructor parameter available
        /// everywhere. Used by `LiveReconstructionGenerator` to attach the color frame it already
        /// re-extracted from the saved video, without `RecordedFrameData` itself ever needing to
        /// store color data.
        func withLumaSource(_ lumaSource: LumaSource) -> DepthGroundingContext {
            DepthGroundingContext(
                cameraTransform: cameraTransform,
                intrinsics: intrinsics,
                imageResolution: imageResolution,
                depthMap: depthMap,
                confidenceMap: confidenceMap,
                deviceOrientation: deviceOrientation,
                lumaSource: lumaSource
            )
        }
    }

    /// Grounds a single joint's position in real LiDAR depth instead of trusting Vision's own
    /// depth estimate.
    ///
    /// Why: monocular 3D pose estimation (what Vision does here) is well known to be reasonably
    /// accurate at 2D image-plane bearing — which pixel a joint projects to — but unreliable at
    /// depth-from-camera (the Z axis), since a single 2D image is fundamentally ambiguous about
    /// absolute distance. That's almost certainly both why calibrated height was off AND why the
    /// Step 4 skeleton could end up at the wrong distance from the wall (sometimes behind/inside
    /// it) — those are the same underlying problem (bad Z), not two separate bugs. We have a
    /// real depth sensor sitting right there, so: trust Vision's bearing (which pixel), replace
    /// its depth guess with LiDAR's actual measurement at that pixel.
    ///
    /// Returns a CAMERA-SPACE position (ARKit convention — combine with `cameraTransform` to get
    /// world space) and whether it's actually LiDAR-grounded. NEVER returns nil — every early-out
    /// below (behind the camera, projected outside the frame, no confident depth nearby, or LiDAR
    /// and Vision disagreeing wildly) falls back to `visionOnlyFallback` (Vision's own, less
    /// reliable, depth-from-camera estimate for THIS joint) with `isGrounded: false`, rather than
    /// discarding the position entirely. Callers that need an all-or-nothing per-FRAME answer
    /// (`groundAllJoints`, used by calibration's cross-frame averaging — see its doc comment for
    /// why partial results are actually harmful there) just check `isGrounded` and bail themselves;
    /// callers that want to keep whatever real depth they can get on a per-JOINT basis
    /// (`groundJointsBestEffort`, used by Step 4's single-frame skeleton) use the returned position
    /// either way.
    ///
    /// Same grounding math as before, but taking already-locked raw buffer pointers instead of a
    /// `DepthGroundingContext` — factored out so callers can lock the depth/confidence buffers
    /// ONCE for all 17 joints instead of re-locking per joint (locking is cheap per call, but
    /// Step 2 calls this at ~15Hz live, so it adds up).
    private static func lidarGroundedCameraSpacePosition(
        rootRelative: SIMD3<Float>,
        cameraOriginMatrix: simd_float4x4,
        intrinsics: simd_float3x3,
        imageResolution: CGSize,
        deviceOrientation: UIDeviceOrientation,
        depthWidth: Int,
        depthHeight: Int,
        depthBase: UnsafeMutableRawPointer,
        depthBytesPerRow: Int,
        confidenceBase: UnsafeMutableRawPointer?,
        confidenceBytesPerRow: Int,
        luma: LockedLuma?
    ) -> (position: SIMD3<Float>, isGrounded: Bool) {
        let local = SIMD4<Float>(rootRelative.x, rootRelative.y, rootRelative.z, 1)
        let visionCameraSpace4 = cameraOriginMatrix * local
        let visionOnlyFallback = SIMD3<Float>(visionCameraSpace4.x, visionCameraSpace4.y, visionCameraSpace4.z)

        // ARKit camera space: X-right, Y-up, Z-backward (camera looks down -Z). Convert to the
        // standard pixel-projection convention (X-right, Y-down, Z-forward-positive).
        let xCV = visionCameraSpace4.x
        let yCV = -visionCameraSpace4.y
        let zCV = -visionCameraSpace4.z
        guard zCV > 0.05 else { return (visionOnlyFallback, false) } // behind/at the camera — degenerate

        // `detect(in:)` runs Vision with an orientation hint so ITS OWN body-pose detection sees
        // an upright person — but that means (xCV, yCV) above is a bearing in that ROTATED/
        // upright frame, not the raw, native-sensor-orientation frame that `intrinsics` and the
        // depth/confidence buffers are actually captured in (ARKit never rotates those).
        // Projecting a rotated-frame bearing straight through raw intrinsics silently swaps/flips
        // axes — which reads visually as "the whole skeleton is coherently shaped, just rotated,"
        // exactly what was reported. `deviceOrientation` here MUST be the same value that was
        // passed to the `detect(in:)` call that produced `cameraOriginMatrix` — for a Step 4
        // stored frame that means the orientation captured back when the frame was RECORDED, not
        // whatever `UIDevice.current.orientation` happens to read NOW (a real, separate bug: the
        // device can easily be held differently by the time the coach taps Generate, minutes
        // after recording — that stale-orientation mismatch was still rotating the skeleton even
        // after the rotation math itself was fixed). Depth (zCV) is unaffected since this
        // rotation is about the optical axis.
        let (rawX, rawY) = rotateBearingToRawSensorFrame(xUp: xCV, yUp: yCV, deviceOrientation: deviceOrientation)

        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let width = Float(imageResolution.width)
        let height = Float(imageResolution.height)

        let u = fx * rawX / zCV + cx
        let v = fy * rawY / zCV + cy
        guard u >= 0, v >= 0, u < width, v < height else { return (visionOnlyFallback, false) } // projected outside the frame

        let depthX = Int(u / width * Float(depthWidth))
        let depthY = Int(v / height * Float(depthHeight))
        guard depthX >= 0, depthX < depthWidth, depthY >= 0, depthY < depthHeight else { return (visionOnlyFallback, false) }

        // Bilateral upgrade: when a color frame is available (`luma` non-nil — see
        // `DepthGroundingContext.lumaSource`'s doc comment for when that is/isn't the case),
        // weight candidate depth pixels by BOTH spatial distance AND how similar their brightness
        // is to this exact joint's own pixel, so a same-surface neighbor (e.g. more of the hand)
        // is trusted over a spatially-closer but different-colored one (e.g. the wall right next
        // to a hand on a hold) — see `bilateralWeightedDepth`'s doc comment. Falls back to the
        // original nearest-valid-neighbor search with NO behavior change whenever `luma` is nil or
        // this exact pixel's brightness can't be read (e.g. projected just outside the color
        // image's own bounds after depth-grid rounding).
        let lidarDepth: Float?
        if let luma, let targetLuma = luma.brightness(x: Int(u), y: Int(v)) {
            lidarDepth = bilateralWeightedDepth(
                depthBase: depthBase, depthBytesPerRow: depthBytesPerRow,
                confidenceBase: confidenceBase, confidenceBytesPerRow: confidenceBytesPerRow,
                depthWidth: depthWidth, depthHeight: depthHeight,
                targetDepthX: depthX, targetDepthY: depthY,
                luma: luma, targetLuma: targetLuma
            ) ?? nearestConfidentDepth(
                depthBase: depthBase, depthBytesPerRow: depthBytesPerRow,
                confidenceBase: confidenceBase, confidenceBytesPerRow: confidenceBytesPerRow,
                width: depthWidth, height: depthHeight, x: depthX, y: depthY
            )
        } else {
            lidarDepth = nearestConfidentDepth(
                depthBase: depthBase, depthBytesPerRow: depthBytesPerRow,
                confidenceBase: confidenceBase, confidenceBytesPerRow: confidenceBytesPerRow,
                width: depthWidth, height: depthHeight, x: depthX, y: depthY
            )
        }
        guard let lidarDepth else {
            return (visionOnlyFallback, false)
        }

        // Sanity guard: reject if LiDAR and Vision wildly disagree, rather than silently
        // producing a garbage position from a sign/axis bug. In practice this fires most often at
        // a body-edge pixel where the confidence-dropout neighbor search (`nearestConfidentDepth`)
        // latches onto the WALL behind/beside the joint instead of the joint itself (e.g. a hand
        // near a hold, where the hand's own depth reading is unreliable but the wall right next to
        // it isn't) — a real, confident LiDAR reading, just of the wrong surface, not a sign/axis
        // bug. Rejecting it here and falling back to Vision-only for JUST this one joint (rather
        // than the whole frame — see `groundJointsBestEffort`) is what keeps that single bad
        // reading from throwing away every other joint's perfectly good real depth.
        let ratio = lidarDepth / zCV
        guard ratio.isFinite, ratio > 0.3, ratio < 3.0 else {
            DebugLog.reconstruction.error("LiDAR grounding rejected an outlier joint (LiDAR=\(lidarDepth, privacy: .public)m vs Vision=\(zCV, privacy: .public)m)")
            return (visionOnlyFallback, false)
        }

        // Unproject the SAME pixel using LiDAR's real depth instead of Vision's estimated
        // depth — keeps Vision's (generally reliable) 2D bearing, replaces its (generally
        // unreliable) depth-from-camera estimate with a real sensor measurement.
        let trueXcv = (u - cx) * lidarDepth / fx
        let trueYcv = (v - cy) * lidarDepth / fy
        return (SIMD3<Float>(trueXcv, -trueYcv, -lidarDepth), true)
    }

    /// Rotates a bearing that's in Vision's "corrected/upright" image-plane convention (X-right,
    /// Y-down — what you get from `detect(in:)`'s orientation hint) into the RAW,
    /// native-sensor-orientation frame that `intrinsics` and the depth/confidence buffers are
    /// actually captured in. See the doc comment where this is called for why this exists.
    ///
    /// `deviceOrientation` must be the SAME value that was passed to the `detect(in:)` call for
    /// this frame — see `DepthGroundingContext.deviceOrientation`'s doc comment.
    ///
    /// Derivation: `cameraOrientation(for:)`'s `.right` (the common portrait case) means "rotate
    /// the raw buffer 90° clockwise to view it upright." Working through that rotation in
    /// centered (X-right, Y-down) coordinates and inverting it gives `rawX = yUp, rawY = -xUp`
    /// for portrait; the other three device orientations follow the same derivation.
    ///
    /// EMPIRICALLY DIRECTED, NOT COMPILE-VERIFIED: the portrait case's direction was chosen to
    /// match a real on-device report ("skeleton needs to rotate counterclockwise ~90° to line up
    /// with the wall"). That test also turned up a SEPARATE bug this rotation direction alone
    /// couldn't explain — grounding was reading `UIDevice.current.orientation` fresh instead of
    /// the orientation the frame now being processed was actually captured in (fixed by
    /// `deviceOrientation` being an explicit, stored-per-frame parameter here rather than a live
    /// read) — so this direction is still only as verified as that one test round. If it's now
    /// wrong the OTHER way (over-rotated, or newly mirrored), the fix is a one-line swap here —
    /// negate/exchange the returned pair for the relevant orientation case — not a re-derivation
    /// from scratch.
    private static func rotateBearingToRawSensorFrame(xUp: Float, yUp: Float, deviceOrientation: UIDeviceOrientation) -> (x: Float, y: Float) {
        switch deviceOrientation {
        case .landscapeLeft:
            return (xUp, yUp) // .up — raw sensor already matches
        case .landscapeRight:
            return (-xUp, -yUp) // .down — 180°
        case .portraitUpsideDown:
            return (-yUp, xUp) // .left — 90° the other way from portrait
        default: // .portrait (the common handheld case) and unknown/faceUp/faceDown
            return (yUp, -xUp) // .right
        }
    }

    /// Projects every joint Vision detected in `sample` to its 2D pixel location in the RAW
    /// (unrotated) camera frame it was detected in — Vision's OWN bearing, reprojected through
    /// the SAME intrinsics/orientation math `lidarGroundedCameraSpacePosition` uses, but with NO
    /// depth lookup at all (no `DepthGroundingContext` needed, works from a `BodyPoseSample`
    /// alone). PURELY for visualization: lets a coach draw Vision's detected skeleton directly on
    /// top of the source video frame to sanity-check "does Vision even see this climber's pose
    /// correctly here" BEFORE spending time on the heavier Generate/Estimate 3D step that builds
    /// on this exact same detection.
    ///
    /// Returns raw pixel coordinates in `imageResolution`'s space (matching `VideoFrameExtractor`
    /// /`ARFrame.capturedImage`'s native, unrotated layout) — the caller is responsible for
    /// rotating the drawn result to an upright display orientation, exactly like `cameraOrientation
    /// (for:)` already does for handing this same raw frame to Vision. A joint that's behind the
    /// camera or projects outside the frame is simply omitted (mirrors
    /// `lidarGroundedCameraSpacePosition`'s early-outs) rather than returning a wrong/clamped
    /// point.
    static func projected2DImagePoints(
        from sample: BodyPoseSample,
        intrinsics: simd_float3x3,
        imageResolution: CGSize,
        deviceOrientation: UIDeviceOrientation
    ) -> [BodyJointName: CGPoint] {
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let width = Float(imageResolution.width)
        let height = Float(imageResolution.height)

        var points: [BodyJointName: CGPoint] = [:]
        for (joint, local) in sample.rootRelativePositions {
            let local4 = SIMD4<Float>(local.x, local.y, local.z, 1)
            let cameraSpace4 = sample.cameraOriginMatrix * local4
            // Same ARKit-camera-space -> pixel-projection-convention conversion as
            // `lidarGroundedCameraSpacePosition` — see its comment for why (X-right, Y-up,
            // Z-backward -> X-right, Y-down, Z-forward-positive).
            let xCV = cameraSpace4.x
            let yCV = -cameraSpace4.y
            let zCV = -cameraSpace4.z
            guard zCV > 0.05 else { continue } // behind/at the camera — degenerate

            let (rawX, rawY) = rotateBearingToRawSensorFrame(xUp: xCV, yUp: yCV, deviceOrientation: deviceOrientation)
            let u = fx * rawX / zCV + cx
            let v = fy * rawY / zCV + cy
            guard u >= 0, v >= 0, u < width, v < height else { continue } // projected outside the frame
            points[joint] = CGPoint(x: CGFloat(u), y: CGFloat(v))
        }
        return points
    }

    /// Grounds every joint in `positions` in real LiDAR depth. Returns nil — never a PARTIAL
    /// result — if any single joint fails to ground, so callers never end up silently mixing
    /// LiDAR-grounded (accurate) and Vision-only (less accurate) joints within one skeleton,
    /// which would distort every distance/height measurement between a grounded and
    /// un-grounded joint. Callers should fall back to the un-grounded `worldPosition` for the
    /// WHOLE frame when this returns nil.
    ///
    /// USE THIS for calibration's cross-frame height averaging (`CalibrationView`), where mixing
    /// grounded and ungrounded joints WITHIN one frame's average would corrupt the result. For
    /// Step 4's single-frame skeleton display, use `groundJointsBestEffort` instead — see its doc
    /// comment for why an all-or-nothing per-frame result is the wrong tradeoff there.
    static func groundAllJoints(
        _ positions: [BodyJointName: SIMD3<Float>],
        cameraOriginMatrix: simd_float4x4,
        context: DepthGroundingContext
    ) -> [BodyJointName: SIMD3<Float>]? {
        guard let buffers = lockedDepthBuffers(context: context) else { return nil }
        defer { buffers.unlock() }

        var grounded: [BodyJointName: SIMD3<Float>] = [:]
        grounded.reserveCapacity(positions.count)
        for (joint, local) in positions {
            let result = lidarGroundedCameraSpacePosition(
                rootRelative: local,
                cameraOriginMatrix: cameraOriginMatrix,
                intrinsics: context.intrinsics,
                imageResolution: context.imageResolution,
                deviceOrientation: context.deviceOrientation,
                depthWidth: buffers.depthWidth,
                depthHeight: buffers.depthHeight,
                depthBase: buffers.depthBase,
                depthBytesPerRow: buffers.depthBytesPerRow,
                confidenceBase: buffers.confidenceBase,
                confidenceBytesPerRow: buffers.confidenceBytesPerRow,
                luma: buffers.luma
            )
            guard result.isGrounded else { return nil }
            grounded[joint] = result.position
        }
        return grounded
    }

    /// Grounds as many joints as possible in real LiDAR depth, keeping Vision's own estimate ONLY
    /// for the specific joint(s) that couldn't be grounded — unlike `groundAllJoints`, one bad
    /// joint (e.g. a hand's confidence-dropout neighbor search latching onto the wall behind it —
    /// see `lidarGroundedCameraSpacePosition`'s sanity-guard doc comment) no longer throws away
    /// every OTHER joint's perfectly good real depth measurement too.
    ///
    /// Use this for Step 4's single-frame skeleton (`ReconstructionEntityBuilder.worldJointPositions`),
    /// where a real recording easily has depth data for 16/17 joints and "17/17 joints are less
    /// accurate" is a strictly worse outcome than "16/17 joints are accurate, one is estimated."
    /// Do NOT use this for cross-frame averaging (calibration) — see `groundAllJoints`'s doc
    /// comment for why partial-per-frame results are actually harmful there.
    ///
    /// Returns the positions (always one per input joint) plus the set of joints that fell back to
    /// Vision-only, so callers can log or visually flag exactly which ones are less certain.
    static func groundJointsBestEffort(
        _ positions: [BodyJointName: SIMD3<Float>],
        cameraOriginMatrix: simd_float4x4,
        context: DepthGroundingContext
    ) -> (positions: [BodyJointName: SIMD3<Float>], ungroundedJoints: Set<BodyJointName>) {
        guard let buffers = lockedDepthBuffers(context: context) else {
            // No usable depth buffer at all — every joint falls back to Vision-only via the same
            // per-joint math `worldPosition(rootRelative:cameraOriginMatrix:cameraTransform:)`
            // uses, computed here directly since there's no depth context to pass through.
            var fallback: [BodyJointName: SIMD3<Float>] = [:]
            for (joint, local) in positions {
                let local4 = SIMD4<Float>(local.x, local.y, local.z, 1)
                let cameraSpace4 = cameraOriginMatrix * local4
                fallback[joint] = SIMD3<Float>(cameraSpace4.x, cameraSpace4.y, cameraSpace4.z)
            }
            return (fallback, Set(positions.keys))
        }
        defer { buffers.unlock() }

        var grounded: [BodyJointName: SIMD3<Float>] = [:]
        grounded.reserveCapacity(positions.count)
        var ungrounded: Set<BodyJointName> = []
        for (joint, local) in positions {
            let result = lidarGroundedCameraSpacePosition(
                rootRelative: local,
                cameraOriginMatrix: cameraOriginMatrix,
                intrinsics: context.intrinsics,
                imageResolution: context.imageResolution,
                deviceOrientation: context.deviceOrientation,
                depthWidth: buffers.depthWidth,
                depthHeight: buffers.depthHeight,
                depthBase: buffers.depthBase,
                depthBytesPerRow: buffers.depthBytesPerRow,
                confidenceBase: buffers.confidenceBase,
                confidenceBytesPerRow: buffers.confidenceBytesPerRow,
                luma: buffers.luma
            )
            grounded[joint] = result.position
            if !result.isGrounded {
                ungrounded.insert(joint)
            }
        }
        if !ungrounded.isEmpty {
            let names = ungrounded.map(\.rawValue).sorted().joined(separator: ", ")
            DebugLog.reconstruction.error("Step 4: \(ungrounded.count, privacy: .public)/\(positions.count, privacy: .public) joint(s) fell back to Vision-only depth (\(names, privacy: .public)) — the rest kept real LiDAR grounding")
        }
        return (grounded, ungrounded)
    }

    /// Locks `context`'s depth (and, if present, confidence) buffers once and returns everything
    /// `lidarGroundedCameraSpacePosition` needs to read from them — shared by `groundAllJoints` and
    /// `groundJointsBestEffort` so both lock ONCE for all 17 joints rather than per-joint (locking
    /// is cheap per call, but Step 2 calls this at ~15Hz live, so it adds up). Caller MUST call
    /// `unlock()` (typically via `defer`) exactly once, whether or not this returns nil.
    private struct LockedDepthBuffers {
        let depthWidth: Int
        let depthHeight: Int
        let depthBase: UnsafeMutableRawPointer
        let depthBytesPerRow: Int
        let confidenceBase: UnsafeMutableRawPointer?
        let confidenceBytesPerRow: Int
        let depthMap: CVPixelBuffer
        let confidenceMap: CVPixelBuffer?
        /// nil whenever `DepthGroundingContext.lumaSource` was nil, OR locking/reading it failed —
        /// either way, `lidarGroundedCameraSpacePosition` treats a nil `luma` here exactly like
        /// "no color available," falling back to the original nearest-valid-neighbor search with
        /// no behavior change.
        let luma: LockedLuma?

        func unlock() {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
            luma?.unlock()
        }
    }

    private static func lockedDepthBuffers(context: DepthGroundingContext) -> LockedDepthBuffers? {
        let depthMap = context.depthMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            return nil
        }
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        let confidenceMap = context.confidenceMap
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceBytesPerRow = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        return LockedDepthBuffers(
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            depthBase: depthBase,
            depthBytesPerRow: depthBytesPerRow,
            confidenceBase: confidenceBase,
            confidenceBytesPerRow: confidenceBytesPerRow,
            depthMap: depthMap,
            confidenceMap: confidenceMap,
            luma: lockLuma(context.lumaSource)
        )
    }

    /// Prepared, ready-to-read form of a `LumaSource` — locked/decoded ONCE per grounding call
    /// (mirrors `LockedDepthBuffers`' own "lock once, read many times" pattern) and handed to
    /// `bilateralWeightedDepth` for repeated fast per-pixel brightness reads. Caller MUST call
    /// `unlock()` exactly once (handled automatically by `LockedDepthBuffers.unlock()`).
    private struct LockedLuma {
        let width: Int
        let height: Int
        private let pixelBufferBase: UnsafeMutableRawPointer?
        private let pixelBufferBytesPerRow: Int
        private let pixelBufferToUnlock: CVPixelBuffer?
        /// Populated only for the `.cgImage` case (Step 4) — a plain 8-bit grayscale raster of
        /// the WHOLE color frame, decoded once via Core Graphics rather than read byte-by-byte
        /// from the `CGImage`'s own raw data. Deliberately NOT reading `CGImage.dataProvider`'s
        /// raw bytes directly and assuming an R/G/B channel order: that layout depends on the
        /// image's `bitmapInfo`, which varies by source/OS version and isn't worth guessing at
        /// with no compiler/device available to verify it against. Rendering into an explicitly
        /// `CGColorSpaceCreateDeviceGray()` / 8-bit-no-alpha context instead makes Core Graphics
        /// do that color conversion correctly, at the one-time cost of a single CGContext draw
        /// per Step 4 "Generate" (negligible next to the Vision calls already happening in the
        /// same call).
        private let grayscalePixels: [UInt8]?

        init(
            width: Int,
            height: Int,
            pixelBufferBase: UnsafeMutableRawPointer? = nil,
            pixelBufferBytesPerRow: Int = 0,
            pixelBufferToUnlock: CVPixelBuffer? = nil,
            grayscalePixels: [UInt8]? = nil
        ) {
            self.width = width
            self.height = height
            self.pixelBufferBase = pixelBufferBase
            self.pixelBufferBytesPerRow = pixelBufferBytesPerRow
            self.pixelBufferToUnlock = pixelBufferToUnlock
            self.grayscalePixels = grayscalePixels
        }

        /// Returns a 0-255 brightness value at (x, y), or nil if out of bounds. For the
        /// `.pixelBuffer` case this reads plane 0 of a bi-planar YCbCr buffer (luma), matching
        /// exactly what `VNImageRequestHandler`/Vision itself reads for detection — the SAME
        /// surface, so "similar brightness" genuinely means "likely the same physical surface."
        func brightness(x: Int, y: Int) -> Float? {
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            if let pixelBufferBase {
                let value = (pixelBufferBase + y * pixelBufferBytesPerRow).assumingMemoryBound(to: UInt8.self)[x]
                return Float(value)
            }
            if let grayscalePixels {
                return Float(grayscalePixels[y * width + x])
            }
            return nil
        }

        func unlock() {
            if let pixelBufferToUnlock {
                CVPixelBufferUnlockBaseAddress(pixelBufferToUnlock, .readOnly)
            }
        }
    }

    /// Prepares a `LumaSource` for repeated fast brightness reads — nil (a soft failure, not a
    /// hard error) whenever `source` is nil, or the underlying buffer/image couldn't be
    /// locked/decoded, either of which just means "grounding falls back to the original
    /// nearest-valid-neighbor search for this frame" rather than aborting anything.
    private static func lockLuma(_ source: LumaSource?) -> LockedLuma? {
        guard let source else { return nil }
        switch source {
        case .pixelBuffer(let buffer):
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                return nil
            }
            return LockedLuma(
                width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                height: CVPixelBufferGetHeightOfPlane(buffer, 0),
                pixelBufferBase: base,
                pixelBufferBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                pixelBufferToUnlock: buffer
            )
        case .cgImage(let image):
            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height)
            let didDraw: Bool = pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard didDraw else { return nil }
            return LockedLuma(width: width, height: height, grayscalePixels: pixels)
        }
    }

    /// Bilateral-weighted depth lookup — the fix for the "hand near a hold grabs the wall's depth
    /// instead of the hand's" failure mode: a wall pixel a couple grid-cells away is often the
    /// FIRST valid depth `nearestConfidentDepth`'s plain nearest-neighbor search finds (LiDAR
    /// confidence tends to drop out right at a hand/hold's own edge), even though it's the wrong
    /// surface. This averages every candidate within `searchRadius`, weighting each one by both
    /// spatial closeness AND how similar its color-frame brightness is to the target joint's own
    /// pixel — a same-surface neighbor (e.g. more of the hand) scores far higher than a
    /// spatially-closer but different-colored one (e.g. the wall right beside it), even when the
    /// wall pixel is technically nearer. Mirrors the joint/cross-bilateral-upsampling idea from
    /// https://www.mdpi.com/1424-8220/23/19/8216 (the same paper `nearestConfidentDepth` already
    /// cites), extended with the color/luma similarity term that paper's Section 3 proposes.
    ///
    /// Returns nil (falls back to `nearestConfidentDepth` at the call site) if no candidate in the
    /// search window has both a valid depth reading AND a readable brightness value.
    private static func bilateralWeightedDepth(
        depthBase: UnsafeMutableRawPointer,
        depthBytesPerRow: Int,
        confidenceBase: UnsafeMutableRawPointer?,
        confidenceBytesPerRow: Int,
        depthWidth: Int,
        depthHeight: Int,
        targetDepthX: Int,
        targetDepthY: Int,
        luma: LockedLuma,
        targetLuma: Float,
        searchRadius: Int = 4,
        spatialSigma: Float = 2.0,
        lumaSigma: Float = 25.0
    ) -> Float? {
        func rawDepth(_ px: Int, _ py: Int) -> Float? {
            guard px >= 0, px < depthWidth, py >= 0, py < depthHeight else { return nil }
            let value = (depthBase + py * depthBytesPerRow).assumingMemoryBound(to: Float32.self)[px]
            guard value.isFinite, value > 0 else { return nil }
            if let confidenceBase {
                let raw = (confidenceBase + py * confidenceBytesPerRow).assumingMemoryBound(to: UInt8.self)[px]
                guard let level = ARConfidenceLevel(rawValue: Int(raw)), level.rawValue >= ARConfidenceLevel.medium.rawValue else {
                    return nil
                }
            }
            return value
        }

        // The color image and the depth grid are very likely different resolutions (e.g. a
        // 1920x1440 color frame vs. a much coarser LiDAR depth grid) — this scales a depth-grid
        // coordinate into the color/luma image's own coordinate space for each candidate.
        let lumaScaleX = Float(luma.width) / Float(depthWidth)
        let lumaScaleY = Float(luma.height) / Float(depthHeight)

        var weightedDepthSum: Float = 0
        var weightSum: Float = 0
        for dy in -searchRadius...searchRadius {
            for dx in -searchRadius...searchRadius {
                let px = targetDepthX + dx
                let py = targetDepthY + dy
                guard let depth = rawDepth(px, py) else { continue }
                let lx = Int(Float(px) * lumaScaleX)
                let ly = Int(Float(py) * lumaScaleY)
                guard let candidateLuma = luma.brightness(x: lx, y: ly) else { continue }

                let spatialDistSq = Float(dx * dx + dy * dy)
                let spatialWeight = exp(-spatialDistSq / (2 * spatialSigma * spatialSigma))
                let lumaDiff = candidateLuma - targetLuma
                let lumaWeight = exp(-(lumaDiff * lumaDiff) / (2 * lumaSigma * lumaSigma))
                let weight = spatialWeight * lumaWeight

                weightedDepthSum += depth * weight
                weightSum += weight
            }
        }
        // A near-zero total weight means every candidate was either invalid or scored as "surely
        // a different surface" — not enough signal to trust an average, so let the caller fall
        // back to plain nearest-valid-neighbor instead.
        guard weightSum > 0.01 else { return nil }
        return weightedDepthSum / weightSum
    }

    /// Searches a small expanding-ring neighborhood around (x,y) for the nearest pixel with a
    /// valid, confident depth reading, instead of rejecting outright on the very first miss.
    /// Scattered per-pixel confidence dropout is a known LiDAR/ARKit artifact — especially over
    /// dark or reflective surfaces, which climbing holds often are — so treating every dropout
    /// pixel as "no data" was silently throwing away joints (and, in the wall mesh, punching
    /// visible holes) far more often than the depth sensor actually failed nearby. Mirrors the
    /// grid-neighbor-averaging idea in https://www.mdpi.com/1424-8220/23/19/8216 (kd-tree over 9
    /// neighboring grid points, averaging the 3 closest) — this uses nearest-valid rather than an
    /// average of several, which is simpler and enough of an improvement for this MVP.
    private static func nearestConfidentDepth(
        depthBase: UnsafeMutableRawPointer,
        depthBytesPerRow: Int,
        confidenceBase: UnsafeMutableRawPointer?,
        confidenceBytesPerRow: Int,
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        maxRadius: Int = 3
    ) -> Float? {
        func rawDepth(_ px: Int, _ py: Int) -> Float? {
            guard px >= 0, px < width, py >= 0, py < height else { return nil }
            let value = (depthBase + py * depthBytesPerRow).assumingMemoryBound(to: Float32.self)[px]
            guard value.isFinite, value > 0 else { return nil }
            if let confidenceBase {
                let raw = (confidenceBase + py * confidenceBytesPerRow).assumingMemoryBound(to: UInt8.self)[px]
                guard let level = ARConfidenceLevel(rawValue: Int(raw)), level.rawValue >= ARConfidenceLevel.medium.rawValue else {
                    return nil
                }
            }
            return value
        }

        if let direct = rawDepth(x, y) { return direct }

        var best: (depth: Float, distSq: Int)?
        for radius in 1...maxRadius {
            for dy in -radius...radius {
                for dx in -radius...radius {
                    guard max(abs(dx), abs(dy)) == radius else { continue } // only the new outer ring
                    guard let depth = rawDepth(x + dx, y + dy) else { continue }
                    let distSq = dx * dx + dy * dy
                    if best == nil || distSq < best!.distSq {
                        best = (depth, distSq)
                    }
                }
            }
            if best != nil { break } // nearest ring with any hit is good enough
        }
        return best?.depth
    }

    /// Unprojects a single, already-known pixel using its real LiDAR depth — the second half of
    /// `lidarGroundedCameraSpacePosition`'s math, factored out for `detectHands`, which already
    /// has a 2D pixel straight from Vision (no 3D bearing to project first, unlike body joints).
    private static func lidarPosition(atPixel pixel: (x: Int, y: Int), context: DepthGroundingContext) -> SIMD3<Float>? {
        let width = Int(context.imageResolution.width)
        let height = Int(context.imageResolution.height)
        guard pixel.x >= 0, pixel.x < width, pixel.y >= 0, pixel.y < height else { return nil }

        let depthMap = context.depthMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthX = Int(Float(pixel.x) / Float(width) * Float(depthWidth))
        let depthY = Int(Float(pixel.y) / Float(height) * Float(depthHeight))
        guard depthX >= 0, depthX < depthWidth, depthY >= 0, depthY < depthHeight else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        let confidenceMap = context.confidenceMap
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceBytesPerRow = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        guard let depth = nearestConfidentDepth(
            depthBase: depthBase, depthBytesPerRow: depthBytesPerRow,
            confidenceBase: confidenceBase, confidenceBytesPerRow: confidenceBytesPerRow,
            width: depthWidth, height: depthHeight, x: depthX, y: depthY
        ) else {
            return nil
        }

        let fx = context.intrinsics.columns.0.x
        let fy = context.intrinsics.columns.1.y
        let cx = context.intrinsics.columns.2.x
        let cy = context.intrinsics.columns.2.y
        let xCV = (Float(pixel.x) - cx) * depth / fx
        let yCV = (Float(pixel.y) - cy) * depth / fy
        return SIMD3<Float>(xCV, -yCV, -depth)
    }

    private static let handJointMap: [(HandJointName, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .wrist),
        (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip),
    ]

    /// Detects both hands' landmarks and grounds each one in real LiDAR depth to build an actual
    /// 3D hand skeleton. Vision has NO 3D hand pose API — `VNDetectHumanHandPoseRequest` is
    /// image-plane-only (21 2D points per hand) — so unlike body joints, there is no Vision-only
    /// fallback here at all: without a confident depth reading, a hand joint simply isn't placed.
    ///
    /// Deliberately run with `orientation: .up` (raw, unrotated), NOT `cameraOrientation()` like
    /// `detect(in:)` above. Vision's 2D hand points are returned relative to whatever orientation
    /// the handler is told the image is in; keeping it `.up` means those points land directly on
    /// the RAW (unrotated) depth map and intrinsics used for grounding, with no extra "undo
    /// Vision's rotation" transform — one less unverified-on-device coordinate conversion stacked
    /// on top of the ones already flagged in this file. Trade-off: hand detection itself may be
    /// less reliable in portrait (hands appear sideways to the detector) — acceptable since
    /// Step 4 only needs ONE good frame and the coach can try a different paused moment.
    static func detectHands(in pixelBuffer: CVPixelBuffer, context: DepthGroundingContext) -> HandPoseSample {
        runHandDetection(
            handler: VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]),
            context: context
        )
    }

    /// Same request, for a `CGImage` pulled from a saved video file (`VideoFrameExtractor`)
    /// instead of a live/stored ARKit pixel buffer — used by Step 4 (`ContentView.generate()`),
    /// which no longer keeps a live in-memory copy of every recorded frame's color image (see
    /// `RecordedFrameStore`'s doc comment for why: it was the direct cause of an on-device OOM
    /// kill). `cgImage` must be the RAW, unrotated frame (same convention as
    /// `VideoFrameExtractor.extractFrame`/`detect(inVideoFrame:deviceOrientation:)`) — orientation
    /// is still `.up` here regardless, for the same reason the pixel-buffer overload uses `.up`
    /// (see this function's main doc comment above).
    static func detectHands(inVideoFrame cgImage: CGImage, context: DepthGroundingContext) -> HandPoseSample {
        runHandDetection(
            handler: VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]),
            context: context
        )
    }

    private static func runHandDetection(handler: VNImageRequestHandler, context: DepthGroundingContext) -> HandPoseSample {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        do {
            try handler.perform([request])
        } catch {
            DebugLog.reconstruction.error("Hand pose request failed: \(String(describing: error), privacy: .public)")
            return HandPoseSample()
        }
        guard let observations = request.results, !observations.isEmpty else {
            return HandPoseSample()
        }

        let width = Float(context.imageResolution.width)
        let height = Float(context.imageResolution.height)

        var sample = HandPoseSample()
        for observation in observations {
            var joints: [HandJointName: SIMD3<Float>] = [:]
            for (ours, vision) in handJointMap {
                guard let point = try? observation.recognizedPoint(vision), point.confidence > 0.3 else { continue }
                // Vision's normalized points have origin at BOTTOM-left; our pixel convention
                // (matching the rest of this file) has origin at TOP-left.
                let px = Int(Float(point.location.x) * width)
                let py = Int((1 - Float(point.location.y)) * height)
                guard let cameraSpace = lidarPosition(atPixel: (px, py), context: context) else { continue }
                joints[ours] = cameraSpace // CAMERA-SPACE — caller converts to world space
            }
            guard !joints.isEmpty else { continue }
            switch observation.chirality {
            case .left: sample.leftHandJoints = joints
            case .right: sample.rightHandJoints = joints
            default: break
            }
        }
        DebugLog.reconstruction.info("Hand pose: left=\(sample.leftHandJoints.count, privacy: .public)/21 joints, right=\(sample.rightHandJoints.count, privacy: .public)/21 joints")
        return sample
    }

    /// Converts an already-camera-space position (e.g. from `lidarGroundedCameraSpacePosition`,
    /// or the intermediate result of `cameraOriginMatrix * rootRelativePoint`) into ARKit world
    /// space using the SAME frame's camera transform.
    static func worldPosition(cameraSpace: SIMD3<Float>, cameraTransform: simd_float4x4) -> SIMD3<Float> {
        let world = cameraTransform * SIMD4<Float>(cameraSpace, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    /// Converts a root-relative joint position into ARKit world space using Vision's OWN
    /// estimate end-to-end (no LiDAR grounding) — the fallback path for when
    /// `groundAllJoints`/`lidarGroundedCameraSpacePosition` can't get a confident real-depth
    /// reading for a frame.
    ///
    /// Composition: world = cameraTransform * cameraOriginMatrix * rootRelativePoint.
    /// `cameraOriginMatrix` is documented by Apple as "a transform from the skeleton hip to the
    /// camera" — by ARKit's own naming convention (an X-to-Y transform maps points FROM X-space
    /// TO Y-space, e.g. ARCamera.transform maps camera space to world space), that reads as
    /// hip-space -> camera-space. This path is noticeably less accurate than the LiDAR-grounded
    /// one (Vision's own absolute depth/scale is the known-weak axis) — prefer
    /// `groundAllJoints` wherever real depth is available.
    static func worldPosition(
        rootRelative: SIMD3<Float>,
        cameraOriginMatrix: simd_float4x4,
        cameraTransform: simd_float4x4
    ) -> SIMD3<Float> {
        let local = SIMD4<Float>(rootRelative.x, rootRelative.y, rootRelative.z, 1)
        let cameraSpace4 = cameraOriginMatrix * local
        let cameraSpace = SIMD3<Float>(cameraSpace4.x, cameraSpace4.y, cameraSpace4.z)
        return worldPosition(cameraSpace: cameraSpace, cameraTransform: cameraTransform)
    }

    /// Standard mapping for ARKit's back-camera `capturedImage` buffer (native landscape-right
    /// sensor orientation) into the orientation Vision expects, given the device orientation AT
    /// THE MOMENT THE FRAME WAS CAPTURED (see `detect(in:deviceOrientation:)`'s doc comment for
    /// why this must be passed in rather than read live from `UIDevice.current.orientation`
    /// here).
    private static func cameraOrientation(for deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
        switch deviceOrientation {
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        case .portraitUpsideDown: return .left
        default: return .right
        }
    }
}

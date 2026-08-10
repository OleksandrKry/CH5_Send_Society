import SwiftUI
import ARKit
import simd

/// Root navigation for the 4-step MVP pipeline. Owns the single shared ARSessionManager
/// instance for the lifetime of the app so Steps 1-3 always see the same ARSession (see
/// ARSessionManager's doc comment for why this matters).
struct ContentView: View {
    @StateObject private var arManager = ARSessionManager()
    @State private var step: AppStep = .wallScan
    @State private var calibration: CalibrationResult?
    @State private var reconstructionInput: ReconstructionInput?

    // Owned here (not inside RecordingView) so navigating Step 4 -> back -> Step 3 re-shows the
    // already-recorded clip for a re-pick instead of losing it and dropping back to record/stop.
    @StateObject private var recorder = VideoRecorder()
    @State private var recordedURL: URL?

    var body: some View {
        Group {
            if !LiDARSupport.isSupported {
                unsupportedDeviceView
            } else {
                stepContent
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .wallScan:
            WallScanView(arManager: arManager) {
                step = .calibration
            }
        case .calibration:
            CalibrationView(arManager: arManager) { result in
                calibration = result
                step = .recording
            }
        case .recording:
            RecordingView(arManager: arManager, recorder: recorder, recordedURL: $recordedURL) { url, frameStore, pausedSeconds in
                reconstructionInput = ReconstructionInput(videoURL: url, frameStore: frameStore, pausedSeconds: pausedSeconds)
                step = .reconstruction
            }
        case .reconstruction:
            if let input = reconstructionInput {
                ReconstructionHost(arManager: arManager, input: input) {
                    // recordedURL is still set (owned by ContentView), so re-entering .recording
                    // goes straight back to the scrubber instead of the record button.
                    step = .recording
                }
            }
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

/// Bundled hand-off data from Step 3 into Step 4.
struct ReconstructionInput {
    let videoURL: URL
    let frameStore: RecordedFrameStore
    let pausedSeconds: TimeInterval
}

/// Runs the Step 4 Vision request for the paused frame once, then hosts ReconstructionView.
/// Kept separate from ContentView so the Vision call happens exactly once per "Generate" tap
/// rather than on every SwiftUI body re-evaluation.
private struct ReconstructionHost: View {
    let arManager: ARSessionManager
    let input: ReconstructionInput
    let onBack: () -> Void

    @State private var poseSample: BodyPoseSample?
    @State private var cameraTransform: simd_float4x4 = matrix_identity_float4x4
    @State private var depthContext: BodyPose3DExtractor.DepthGroundingContext?
    /// Classify-then-snap-to-preset results for each limb — see `GripClassifier`. Each is
    /// computed for the exact paused frame first; if confidence comes in below
    /// `GripClassifier.confidenceThreshold`, `generate()`'s nearby-frame fallback (mirroring the
    /// approach already used for raw hand-position recovery) searches nearby moments in the same
    /// clip for a more confident answer for THAT specific limb.
    @State private var leftGrip: GripClassification?
    @State private var rightGrip: GripClassification?
    @State private var leftFoot: FootClassification?
    @State private var rightFoot: FootClassification?
    /// Non-nil only when the corresponding classification above was recovered from a nearby frame
    /// instead of the exact paused one — surfaced in the UI as an explicit "estimated from Xs
    /// earlier/later" label.
    @State private var leftGripOffsetSeconds: TimeInterval?
    @State private var rightGripOffsetSeconds: TimeInterval?
    @State private var leftFootOffsetSeconds: TimeInterval?
    @State private var rightFootOffsetSeconds: TimeInterval?
    @State private var poseError: String?
    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                ReconstructionView(
                    // wallMeshSnapshot (frozen at Step 1 "Done"), NOT the live meshAnchors —
                    // see ARSessionManager.wallMeshSnapshot for why: the live list keeps growing
                    // through Steps 2-3 and picks up floor/clutter/residual body-shaped mesh.
                    wallAnchors: arManager.wallMeshSnapshot,
                    wallTextureReference: arManager.wallTextureReference,
                    poseSample: poseSample,
                    cameraTransform: cameraTransform,
                    depthContext: depthContext,
                    leftGrip: leftGrip,
                    rightGrip: rightGrip,
                    leftFoot: leftFoot,
                    rightFoot: rightFoot,
                    leftGripOffsetSeconds: leftGripOffsetSeconds,
                    rightGripOffsetSeconds: rightGripOffsetSeconds,
                    leftFootOffsetSeconds: leftFootOffsetSeconds,
                    rightFootOffsetSeconds: rightFootOffsetSeconds,
                    poseError: poseError,
                    onBack: onBack
                )
            } else {
                ProgressView("Reconstructing…")
            }
        }
        .onAppear(perform: generate)
    }

    private func generate() {
        guard let frameData = input.frameStore.nearestFrame(toPlaybackSeconds: input.pausedSeconds) else {
            poseError = "No stored depth/camera data for this moment in the video."
            let seconds = input.pausedSeconds
            DebugLog.reconstruction.error("No RecordedFrameData found near playback second \(seconds, privacy: .public)")
            isReady = true
            return
        }
        cameraTransform = frameData.cameraTransform
        // Same real depth data the wall mesh itself was built from — this is what lets Step 4
        // place the skeleton against the wall using real measurements instead of Vision's own
        // (much less reliable) depth estimate.
        depthContext = frameData.depthGroundingContext
        if depthContext == nil {
            DebugLog.reconstruction.error("No depth data for this paused frame — skeleton placement will use Vision's raw (less accurate) estimate")
        }
        do {
            // MUST use frameData's OWN stored orientation, not "current" — Step 4 can run
            // minutes after this frame was actually recorded, by which point the device may be
            // held completely differently. Using current orientation here was the real root
            // cause of the skeleton coming out rotated relative to the wall (see
            // RecordedFrameData.deviceOrientation's doc comment for the full story).
            poseSample = try BodyPose3DExtractor.detect(in: frameData.capturedImage, deviceOrientation: frameData.deviceOrientation)
        } catch {
            poseError = "No body pose detected in this frame — try a different moment in the video."
            let description = String(describing: error)
            DebugLog.reconstruction.error("Body pose detection failed for reconstruction: \(description, privacy: .public)")
        }
        guard let poseSample else {
            // No body detected at all in this frame — nothing to classify grips/feet against
            // (classification needs real wrist/ankle world positions). `poseError` above already
            // tells the coach to try a different moment.
            isReady = true
            return
        }

        // Grip/foot-placement classification replaces raw finger/toe reconstruction here — see
        // GripClassifier's doc comment for why. Hand landmarks (whatever Vision could detect,
        // which is often sparse or empty on an occluded grip) are still computed as an INPUT to
        // classification, same as before — they're just no longer rendered directly as raw
        // fingertip geometry.
        let mainHandSample: HandPoseSample? = depthContext.map {
            BodyPose3DExtractor.detectHands(in: frameData.capturedImage, context: $0)
        }
        let mainClassification = ReconstructionEntityBuilder.classifyGripsAndFeet(
            poseSample: poseSample,
            cameraTransform: cameraTransform,
            depthContext: depthContext,
            handSample: mainHandSample,
            handCameraTransform: cameraTransform,
            wallReference: arManager.wallTextureReference
        )
        leftGrip = mainClassification.leftHand
        rightGrip = mainClassification.rightHand
        leftFoot = mainClassification.leftFoot
        rightFoot = mainClassification.rightFoot
        leftGripOffsetSeconds = nil
        rightGripOffsetSeconds = nil
        leftFootOffsetSeconds = nil
        rightFootOffsetSeconds = nil

        func meets(_ c: GripClassification?) -> Bool { (c?.confidence ?? 0) >= GripClassifier.confidenceThreshold }
        func meetsFoot(_ c: FootClassification?) -> Bool { (c?.confidence ?? 0) >= GripClassifier.confidenceThreshold }

        // Same idea as the raw-hand nearby-frame fallback this replaces: a fully gripped/wedged
        // limb is close to worst-case for classification on the EXACT paused frame, so if any
        // slot came back low-confidence, search nearby moments in the same clip (the reach just
        // before contact, or the release just after, are the usual candidates) for a more
        // confident answer for THAT specific limb. Each candidate frame is analyzed (body pose +
        // hands) ONCE and reused across all four slots, rather than re-running Vision per slot —
        // capped at 8 candidates to bound how many extra Vision calls one "Generate" tap can
        // trigger.
        if !meets(leftGrip) || !meets(rightGrip) || !meetsFoot(leftFoot) || !meetsFoot(rightFoot) {
            let candidates = Array(input.frameStore.nearbyFrames(toPlaybackSeconds: input.pausedSeconds, withinSeconds: 1.5).prefix(8))
            for candidate in candidates {
                guard let candidateDepthContext = candidate.depthGroundingContext,
                      let candidatePose = try? BodyPose3DExtractor.detect(in: candidate.capturedImage, deviceOrientation: candidate.deviceOrientation)
                else { continue }
                let candidateHands = BodyPose3DExtractor.detectHands(in: candidate.capturedImage, context: candidateDepthContext)
                let candidateClassification = ReconstructionEntityBuilder.classifyGripsAndFeet(
                    poseSample: candidatePose,
                    cameraTransform: candidate.cameraTransform,
                    depthContext: candidateDepthContext,
                    handSample: candidateHands,
                    handCameraTransform: candidate.cameraTransform,
                    wallReference: arManager.wallTextureReference
                )
                let offset = candidate.timestamp - frameData.timestamp

                if !meets(leftGrip), meets(candidateClassification.leftHand) {
                    leftGrip = candidateClassification.leftHand
                    leftGripOffsetSeconds = offset
                }
                if !meets(rightGrip), meets(candidateClassification.rightHand) {
                    rightGrip = candidateClassification.rightHand
                    rightGripOffsetSeconds = offset
                }
                if !meetsFoot(leftFoot), meetsFoot(candidateClassification.leftFoot) {
                    leftFoot = candidateClassification.leftFoot
                    leftFootOffsetSeconds = offset
                }
                if !meetsFoot(rightFoot), meetsFoot(candidateClassification.rightFoot) {
                    rightFoot = candidateClassification.rightFoot
                    rightFootOffsetSeconds = offset
                }
            }
        }

        isReady = true
    }
}

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
            RecordingView(arManager: arManager) { url, frameStore, pausedSeconds in
                reconstructionInput = ReconstructionInput(videoURL: url, frameStore: frameStore, pausedSeconds: pausedSeconds)
                step = .reconstruction
            }
        case .reconstruction:
            if let input = reconstructionInput {
                ReconstructionHost(arManager: arManager, input: input)
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

    @State private var poseSample: BodyPoseSample?
    @State private var cameraTransform: simd_float4x4 = matrix_identity_float4x4
    @State private var poseError: String?
    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                ReconstructionView(
                    wallAnchors: arManager.meshAnchors,
                    poseSample: poseSample,
                    cameraTransform: cameraTransform,
                    poseError: poseError
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
        do {
            poseSample = try BodyPose3DExtractor.detect(in: frameData.capturedImage)
        } catch {
            poseError = "No body pose detected in this frame — try a different moment in the video."
            let description = String(describing: error)
            DebugLog.reconstruction.error("Body pose detection failed for reconstruction: \(description, privacy: .public)")
        }
        isReady = true
    }
}

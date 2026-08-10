import SwiftUI
import ARKit

/// Step 2 — Calibrate Climber. Samples the shared ARSession's live frames at ~15Hz through
/// VNDetectHumanBodyPose3DRequest while the climber holds a T-pose, and averages the result via
/// CalibrationEngine.
struct CalibrationView: View {
    @ObservedObject var arManager: ARSessionManager
    @StateObject private var engine = CalibrationEngine()
    let onDone: (CalibrationResult) -> Void

    @State private var isRunning = false
    @State private var timer: Timer?
    @State private var lastError: String?

    var body: some View {
        ZStack(alignment: .top) {
            ARMeshSceneView(session: arManager.session)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                instructions
                Spacer()
                if let result = engine.result {
                    confirmationCard(result)
                } else {
                    progressCard
                }
                actionButton
            }
            .padding()
        }
        .onDisappear { stop() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Step 2 — Calibrate Climber").font(.headline)
            Text("Climber stands facing the camera in a T-pose — arms out to the sides, fully visible head-to-toe, feet on the ground. Hold still for a few seconds.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var progressCard: some View {
        VStack(spacing: 8) {
            if isRunning {
                ProgressView(value: Double(engine.collectedFrameCount), total: Double(engine.targetFrameCount))
                Text("Capturing \(engine.collectedFrameCount)/\(engine.targetFrameCount) frames")
                    .font(.footnote.monospacedDigit())
            } else {
                Text("Tap Start Calibration when the climber is ready.")
                    .font(.footnote)
            }
            if let lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func confirmationCard(_ result: CalibrationResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Captured", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            Text(String(format: "Height: %.2f m", result.segments.height))
            Text(String(format: "Arm span: %.2f m", result.segments.armSpan))
            Text(String(format: "Upper arm: %.2f m · Forearm: %.2f m", result.segments.upperArmLength, result.segments.forearmLength))
            Text(String(format: "Thigh: %.2f m · Shin: %.2f m", result.segments.thighLength, result.segments.shinLength))
            Text("Averaged over \(result.frameCount) frames")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var actionButton: some View {
        if let result = engine.result {
            HStack {
                Button("Recapture") {
                    engine.reset()
                    isRunning = false
                }
                .buttonStyle(.bordered)

                Button("Continue") { onDone(result) }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        } else {
            Button(isRunning ? "Cancel" : "Start Calibration") {
                isRunning ? stop() : start()
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
        }
    }

    private func start() {
        engine.reset()
        isRunning = true
        DebugLog.calibration.info("Calibration capture started")
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in
            captureFrame()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    private func captureFrame() {
        guard let frame = arManager.latestFrame else { return }
        do {
            let sample = try BodyPose3DExtractor.detect(in: frame.capturedImage)
            lastError = nil
            if engine.ingest(sample.rootRelativePositions) {
                stop()
            }
        } catch BodyPoseError.noPersonDetected {
            lastError = "No person detected — make sure the climber is fully in frame"
        } catch {
            lastError = "Pose detection error: \(error.localizedDescription)"
            DebugLog.calibration.error("Pose detection error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

import SwiftUI
import ARKit
import UIKit

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

    /// Live "is there actually a detectable person in frame right now" cue, checked BEFORE the
    /// coach taps Start — so they find out they're too close/far or out of frame immediately,
    /// instead of tapping Start and watching the frame counter never move.
    @State private var isPersonDetected = false
    @State private var readinessTimer: Timer?

    /// Locked in on the first usable frame of a capture session (see `captureFrame`) and held
    /// for the rest of that session. CalibrationEngine averages joint positions across frames,
    /// so every ingested frame in one session MUST be in the same coordinate space — mixing
    /// LiDAR-grounded absolute camera-space positions with Vision-only root-relative positions
    /// across frames would silently corrupt the average.
    private enum GroundingMode { case grounded, ungrounded }
    @State private var groundingMode: GroundingMode?

    var body: some View {
        ZStack(alignment: .top) {
            ARMeshSceneView(session: arManager.session)
                .ignoresSafeArea()

            if engine.result == nil && !isRunning {
                TPoseSilhouette()
                    .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .padding(.horizontal, 50)
                    .padding(.top, 90)
                    .padding(.bottom, 130)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 12) {
                instructions
                if engine.result == nil {
                    readinessBadge
                }
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
        .onAppear {
            readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                checkReadiness()
            }
        }
        .onDisappear {
            stop()
            readinessTimer?.invalidate()
            readinessTimer = nil
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Step 2 — Calibrate Climber").font(.headline)
            Text("Stand ~2-3m back, facing the camera, whole body in frame. Match the outline: arms straight out to the sides at shoulder height (a \"T\"), feet shoulder-width apart, facing forward. Hold completely still for about 3 seconds — the app captures 45 frames and averages them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var readinessBadge: some View {
        Label(
            isPersonDetected ? "Person detected — hold the T-pose" : "No person detected — step into frame",
            systemImage: isPersonDetected ? "checkmark.circle.fill" : "person.fill.questionmark"
        )
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background((isPersonDetected ? Color.green : Color.orange).opacity(0.9), in: Capsule())
        .foregroundStyle(.white)
    }

    private var progressCard: some View {
        VStack(spacing: 8) {
            if isRunning {
                ProgressView(value: Double(engine.collectedFrameCount), total: Double(engine.targetFrameCount))
                Text("Capturing \(engine.collectedFrameCount)/\(engine.targetFrameCount) frames — hold the pose")
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
        groundingMode = nil
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
        // Captured ONCE and passed explicitly to both calls below, rather than letting each one
        // read UIDevice.current.orientation independently — this is the live/current-frame case
        // so either would normally agree, but explicit-and-consistent costs nothing and matches
        // the pattern Step 4 NEEDS (where "current" would be wrong — see
        // RecordedFrameData.deviceOrientation's doc comment).
        let deviceOrientation = UIDevice.current.orientation
        do {
            let sample = try BodyPose3DExtractor.detect(in: frame.capturedImage, deviceOrientation: deviceOrientation)
            lastError = nil

            // Ground every joint in real LiDAR depth instead of trusting Vision's own
            // depth/scale estimate (the known-weak axis for single-view 3D pose — see
            // BodyPose3DExtractor.lidarGroundedCameraSpacePosition for why).
            let context = BodyPose3DExtractor.DepthGroundingContext.from(frame: frame, deviceOrientation: deviceOrientation)
            let grounded = context.flatMap {
                BodyPose3DExtractor.groundAllJoints(sample.rootRelativePositions, cameraOriginMatrix: sample.cameraOriginMatrix, context: $0)
            }

            // Lock in grounded-vs-ungrounded for the WHOLE capture session on the first usable
            // frame — see the `groundingMode` doc comment for why this can't be decided
            // per-frame.
            if groundingMode == nil {
                groundingMode = (grounded != nil) ? .grounded : .ungrounded
                let modeDescription = groundingMode == .grounded ? "LiDAR-grounded" : "Vision-only"
                DebugLog.calibration.info("Calibration locked to \(modeDescription, privacy: .public) mode for this session")
            }

            switch groundingMode! {
            case .grounded:
                guard let grounded else {
                    // Committed to grounded mode but this particular frame didn't ground —
                    // skip it rather than mixing coordinate spaces into the average.
                    lastError = "Momentary tracking dip — hold steady"
                    return
                }
                if engine.ingest(grounded) {
                    stop()
                }
            case .ungrounded:
                if engine.ingest(sample.rootRelativePositions) {
                    stop()
                }
            }
        } catch BodyPoseError.noPersonDetected {
            lastError = "No person detected — make sure the climber is fully in frame"
        } catch {
            lastError = "Pose detection error: \(error.localizedDescription)"
            DebugLog.calibration.error("Pose detection error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs a cheap pre-capture check so the coach sees "step into frame" feedback immediately,
    /// rather than tapping Start Calibration and only discovering something's wrong when the
    /// frame counter refuses to move. Only runs while idle — no point in duplicating work once
    /// `captureFrame()` is already running its own detection at 15Hz.
    private func checkReadiness() {
        guard !isRunning, engine.result == nil, let frame = arManager.latestFrame else { return }
        isPersonDetected = (try? BodyPose3DExtractor.detect(in: frame.capturedImage)) != nil
    }
}

/// A simple stick-figure T-pose outline — arms straight out to the sides, legs shoulder-width
/// apart — for the climber to visually line their body up against before Step 2 starts capturing.
/// Purely a visual guide, drawn proportionally within whatever frame it's given; not tied to any
/// detected joint positions.
private struct TPoseSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let centerX = rect.midX

        let headRadius = h * 0.06
        let headCenterY = rect.minY + headRadius * 1.2
        path.addEllipse(in: CGRect(x: centerX - headRadius, y: headCenterY - headRadius, width: headRadius * 2, height: headRadius * 2))

        let neckY = headCenterY + headRadius
        let hipY = rect.minY + h * 0.55
        let shoulderY = neckY + (hipY - neckY) * 0.12
        let footY = rect.minY + h * 0.98

        // Torso
        path.move(to: CGPoint(x: centerX, y: neckY))
        path.addLine(to: CGPoint(x: centerX, y: hipY))

        // Arms — the "T": straight out to the sides at shoulder height
        path.move(to: CGPoint(x: rect.minX + w * 0.04, y: shoulderY))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.04, y: shoulderY))

        // Legs — shoulder-width apart, down to the bottom of the guide
        path.move(to: CGPoint(x: centerX, y: hipY))
        path.addLine(to: CGPoint(x: centerX - w * 0.12, y: footY))
        path.move(to: CGPoint(x: centerX, y: hipY))
        path.addLine(to: CGPoint(x: centerX + w * 0.12, y: footY))

        return path
    }
}

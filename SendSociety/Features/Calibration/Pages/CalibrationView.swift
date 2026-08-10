import SwiftUI
import ARKit
import UIKit

/// Step 2 — Calibrate Climber. Samples the shared ARSession's live frames at ~15Hz through
/// VNDetectHumanBodyPose3DRequest while the climber holds a T-pose, and averages the result via
/// CalibrationEngine.
struct CalibrationView: View {
    @ObservedObject var arManager: ARSessionManager
    @StateObject private var engine = CalibrationEngine()
    /// `nil` means the coach tapped "Skip" — no climber calibration for this session at all.
    /// Nothing downstream requires a `CalibrationResult` to exist: recording, wall scanning, and
    /// Step 4's wall-only reconstruction (see `ReconstructionEntityBuilder`'s doc comment on
    /// best-effort grounding) all work fine without one — calibration only ever fed height/limb
    /// numbers into it. Added so a coach can jump straight to checking wall-scan/camera-angle
    /// calibration without needing a climber standing there first.
    let onDone: (CalibrationResult?) -> Void

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
    /// across frames would silently corrupt the average. See `CalibrationFrameProcessor
    /// .GroundingMode`'s doc comment (Core/PoseReconstruction) for the full reasoning — the type
    /// lives there now since it's produced by that module's per-frame processing, not by this view.
    @State private var groundingMode: CalibrationFrameProcessor.GroundingMode?

    /// Optional climber-entered height, in centimeters as typed — see `enteredHeightMeters` for
    /// the parsed/validated value and `finalizedResult` for whether (and how) it actually affects
    /// the calibration numbers. Kept as raw text so the TextField can hold intermediate/invalid
    /// input (e.g. a half-typed number) without fighting SwiftUI's binding.
    @State private var heightInputText: String = ""

    /// Parsed height input, or nil if empty/unparseable/outside a plausible adult range —
    /// garbage or partial input is treated as "nothing entered" rather than surfacing an error
    /// for what's an optional field.
    private var enteredHeightMeters: Float? {
        guard let cm = Float(heightInputText), cm >= 100, cm <= 230 else { return nil }
        return cm / 100
    }

    private var heightInputIsInvalid: Bool {
        !heightInputText.isEmpty && enteredHeightMeters == nil
    }

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
                if !isRunning {
                    heightInputCard
                }
                if engine.result == nil {
                    readinessBadge
                }
                Spacer()
                if let finalized {
                    confirmationCard(finalized)
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

    private var heightInputCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Climber height (cm) — optional").font(.footnote.weight(.semibold))
                Spacer()
                TextField("e.g. 175", text: $heightInputText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Used as a cross-check against the measured height — see the note below once captured.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if heightInputIsInvalid {
                Text("Enter a height between 100-230cm, or leave blank.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func confirmationCard(_ finalized: (result: CalibrationResult, heightNote: String?)) -> some View {
        let result = finalized.result
        return VStack(alignment: .leading, spacing: 6) {
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
            if let heightNote = finalized.heightNote {
                Text(heightNote)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var actionButton: some View {
        if let finalized {
            HStack {
                Button("Recapture") {
                    engine.reset()
                    isRunning = false
                }
                .buttonStyle(.bordered)

                Button("Continue") { onDone(finalized.result) }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 8) {
                Button(isRunning ? "Cancel" : "Start Calibration") {
                    isRunning ? stop() : start()
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)

                if !isRunning {
                    Button("Skip Climber Calibration") { onDone(nil) }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// `engine.result` plus whatever the entered height implies about it — computed once here so
    /// `confirmationCard`/`actionButton` (and the "is capture done" check driving which card shows)
    /// all see the exact same finalized numbers.
    private var finalized: (result: CalibrationResult, heightNote: String?)? {
        engine.result.map(finalizedResult)
    }

    /// The actual height-rescaling decision lives in `CalibrationHeightCorrection`
    /// (Core/PoseReconstruction) — see that type's doc comment for the full reasoning on why
    /// `.ungrounded` captures get rescaled but `.grounded` ones only get cross-checked. This is
    /// just wiring this screen's current state (`engine.result`, entered height, locked grounding
    /// mode) to it.
    private func finalizedResult(from result: CalibrationResult) -> (result: CalibrationResult, heightNote: String?) {
        CalibrationHeightCorrection.apply(to: result, enteredHeightMeters: enteredHeightMeters, groundingMode: groundingMode)
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

    /// The actual per-frame algorithm (Vision detection + LiDAR grounding + grounding-mode
    /// decision) lives in `CalibrationFrameProcessor` (Core/PoseReconstruction) — this just drives
    /// the 15Hz `Timer` (see `start()`) and updates this screen's state from whatever `Result`
    /// comes back.
    private func captureFrame() {
        guard let frame = arManager.latestFrame else { return }
        // Captured ONCE and passed explicitly, rather than letting the processor read
        // UIDevice.current.orientation independently — this is the live/current-frame case so
        // either would normally agree, but explicit-and-consistent costs nothing and matches the
        // pattern Step 4 NEEDS (where "current" would be wrong — see RecordedFrameData
        // .deviceOrientation's doc comment).
        let deviceOrientation = UIDevice.current.orientation
        let outcome = CalibrationFrameProcessor.process(
            frame: frame,
            deviceOrientation: deviceOrientation,
            lockedGroundingMode: groundingMode
        )

        switch outcome {
        case .positions(let positions, let mode):
            lastError = nil
            // Lock in grounded-vs-ungrounded for the WHOLE capture session on the first usable
            // frame — see `groundingMode`'s doc comment for why this can't be decided per-frame.
            if groundingMode == nil {
                groundingMode = mode
                let modeDescription = mode == .grounded ? "LiDAR-grounded" : "Vision-only"
                DebugLog.calibration.info("Calibration locked to \(modeDescription, privacy: .public) mode for this session")
            }
            if engine.ingest(positions) {
                stop()
            }
        case .trackingDip:
            lastError = "Momentary tracking dip — hold steady"
        case .noPersonDetected:
            lastError = "No person detected — make sure the climber is fully in frame"
        case .error(let description):
            lastError = "Pose detection error: \(description)"
            DebugLog.calibration.error("Pose detection error: \(description, privacy: .public)")
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

// `TPoseSilhouette` (the visual T-pose guide shape drawn over the camera feed) has moved to
// Features/Calibration/Components/TPoseSilhouette.swift — a reusable rendering primitive, not page
// logic, so it lives separately for a frontend developer to find and edit on its own.

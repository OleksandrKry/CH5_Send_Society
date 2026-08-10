import SwiftUI
import RealityKit
import ARKit
import simd

/// Step 4 — Generate the static 3D view. Non-AR RealityKit scene (no live camera passthrough):
/// the previously-scanned wall mesh + a single-frame skeleton, rendered together in the same
/// coordinate space, with one-finger drag-to-orbit. Static frame only — no animation, no
/// playback, no skeleton dragging (explicitly out of scope for this phase).
struct ReconstructionView: View {
    let wallAnchors: [ARMeshAnchor]
    let wallTextureReference: ARSessionManager.WallTextureReference?
    let poseSample: BodyPoseSample?
    /// The exact ARKit camera transform for the frame being reconstructed, when one is actually
    /// available — nil for a loaded/reviewed reconstruction (no live per-frame pose exists then;
    /// `initialWorldPositions` carries the already-computed positions instead). Used both for
    /// grounding math (only when `poseSample`/no `initialWorldPositions`) AND to seed the initial
    /// 3D-view camera's zoom/angle to match the real recording position — see
    /// `ReconstructionSceneView`'s camera setup. Deliberately Optional rather than defaulting to
    /// `matrix_identity_float4x4`: that placeholder is indistinguishable from a genuine (if very
    /// unlikely) identity transform, and was silently feeding a meaningless "camera at world
    /// origin" position into the camera-seeding math for reviewed reconstructions.
    let cameraTransform: simd_float4x4?
    /// Real LiDAR depth for the SAME paused frame the skeleton was detected in, if it was still
    /// available in RecordedFrameStore — see ReconstructionEntityBuilder.worldJointPositions for
    /// how this is used to ground the skeleton instead of trusting Vision's own depth guess.
    let depthContext: BodyPose3DExtractor.DepthGroundingContext?
    /// Classified grip/foot-placement type + confidence for each limb, if classification could be
    /// attempted at all — see `GripClassifier`. nil, or a confidence below
    /// `GripClassifier.confidenceThreshold`, both render as an honest "uncertain" marker rather
    /// than a named preset (see `ReconstructionEntityBuilder.handAttachmentEntity`).
    let leftGrip: GripClassification?
    let rightGrip: GripClassification?
    let leftFoot: FootClassification?
    let rightFoot: FootClassification?
    /// Non-nil only when the corresponding classification was recovered from a nearby frame
    /// instead of the exact paused one — shown as an explicit "estimated from Xs earlier/later"
    /// label, mirroring the pattern already used for raw hand-position recovery.
    var leftGripOffsetSeconds: TimeInterval? = nil
    var rightGripOffsetSeconds: TimeInterval? = nil
    var leftFootOffsetSeconds: TimeInterval? = nil
    var rightFootOffsetSeconds: TimeInterval? = nil
    let poseError: String?
    var onBack: (() -> Void)? = nil
    /// Called when the coach explicitly says they're done with this whole recording (shown as a
    /// "Done" button) — the caller's job is to return to `LibraryView`. Distinct from `onBack`
    /// (which goes back to Step 3's scrubber to pick a different moment): "Done" ends the pipeline
    /// run entirely, while "Back to video" stays within it.
    var onFinished: (() -> Void)? = nil
    /// Previously-saved 3D-view annotations for this exact reconstruction, if this screen was
    /// reopened from a saved `ReconstructionRecord` (see `Core/Persistence`) rather than freshly
    /// generated — preloaded into `annotationState` on appear. Empty for a brand-new generation.
    var initialAnnotationStrokes: [AnnotationStroke] = []
    /// Called whenever the coach's 3D-view annotations change (add/undo/clear), so the caller can
    /// persist them back into the session — nil (the default) means "don't bother," e.g. for a
    /// reconstruction that was never saved in the first place.
    var onAnnotationStrokesChanged: (([AnnotationStroke]) -> Void)? = nil
    /// The already depth-grounded positions to render when there's no fresh `poseSample`/
    /// `depthContext` to compute from — i.e. a session review reopening a previously-generated
    /// `ReconstructionEntry` (see its doc comment for why regeneration isn't possible then). nil
    /// for a brand-new "Generate" tap, where `poseSample`/`cameraTransform`/`depthContext` are used
    /// as before. Passed straight through to `ReconstructionSceneView`'s `overridePositions`
    /// machinery — from that point on a loaded reconstruction and a freshly-generated one are
    /// handled identically.
    var initialWorldPositions: [BodyJointName: SIMD3<Float>]? = nil
    /// The coach's already-saved manual pose correction for this reconstruction, if any — seeds
    /// `jointOverrides`/`hasEditedPose` at creation (via the custom `init` below) so reopening an
    /// edited reconstruction shows the edit immediately, and "Reset Pose" reverts to
    /// `initialWorldPositions` rather than silently discarding the saved edit.
    var initialJointOverrides: [BodyJointName: SIMD3<Float>]? = nil
    /// Called whenever the coach drags a joint (or taps Reset Pose), so the caller can persist the
    /// correction back into the session — nil (the default) means "don't bother."
    var onJointOverridesChanged: (([BodyJointName: SIMD3<Float>]?) -> Void)? = nil
    /// True for a reconstruction generated later from session review, without real LiDAR depth —
    /// see `ReconstructionEntry.isApproximate`'s doc comment. Shown as an honest banner so the
    /// coach doesn't mistake an estimate for a precise, depth-grounded measurement.
    var isApproximate: Bool = false

    /// True while the coach can drag joints to manually correct the auto-detected pose — see
    /// `SkeletonPoseEditor` for the anatomical constraints applied to every drag, and
    /// `ReconstructionSceneView.Coordinator` for the gesture/hit-testing logic. Gated behind an
    /// explicit toggle (rather than always-on) so an ordinary one-finger orbit drag near a joint
    /// can never accidentally nudge it — dragging only ever means "move this joint" while this is
    /// true, and only ever means "orbit the camera" while it's false.
    @State private var isEditingPose = false
    @State private var isAnnotating = false
    @State private var jointOverrides: [BodyJointName: SIMD3<Float>]?
    @State private var draggedJoint: BodyJointName? = nil
    @State private var hasEditedPose: Bool
    @StateObject private var annotationState = AnnotationState()

    init(
        wallAnchors: [ARMeshAnchor],
        wallTextureReference: ARSessionManager.WallTextureReference?,
        poseSample: BodyPoseSample?,
        cameraTransform: simd_float4x4?,
        depthContext: BodyPose3DExtractor.DepthGroundingContext?,
        leftGrip: GripClassification?,
        rightGrip: GripClassification?,
        leftFoot: FootClassification?,
        rightFoot: FootClassification?,
        leftGripOffsetSeconds: TimeInterval? = nil,
        rightGripOffsetSeconds: TimeInterval? = nil,
        leftFootOffsetSeconds: TimeInterval? = nil,
        rightFootOffsetSeconds: TimeInterval? = nil,
        poseError: String?,
        onBack: (() -> Void)? = nil,
        onFinished: (() -> Void)? = nil,
        initialAnnotationStrokes: [AnnotationStroke] = [],
        onAnnotationStrokesChanged: (([AnnotationStroke]) -> Void)? = nil,
        initialWorldPositions: [BodyJointName: SIMD3<Float>]? = nil,
        initialJointOverrides: [BodyJointName: SIMD3<Float>]? = nil,
        onJointOverridesChanged: (([BodyJointName: SIMD3<Float>]?) -> Void)? = nil,
        isApproximate: Bool = false
    ) {
        self.wallAnchors = wallAnchors
        self.wallTextureReference = wallTextureReference
        self.poseSample = poseSample
        self.cameraTransform = cameraTransform
        self.depthContext = depthContext
        self.leftGrip = leftGrip
        self.rightGrip = rightGrip
        self.leftFoot = leftFoot
        self.rightFoot = rightFoot
        self.leftGripOffsetSeconds = leftGripOffsetSeconds
        self.rightGripOffsetSeconds = rightGripOffsetSeconds
        self.leftFootOffsetSeconds = leftFootOffsetSeconds
        self.rightFootOffsetSeconds = rightFootOffsetSeconds
        self.poseError = poseError
        self.onBack = onBack
        self.onFinished = onFinished
        self.initialAnnotationStrokes = initialAnnotationStrokes
        self.onAnnotationStrokesChanged = onAnnotationStrokesChanged
        self.initialWorldPositions = initialWorldPositions
        self.initialJointOverrides = initialJointOverrides
        self.onJointOverridesChanged = onJointOverridesChanged
        self.isApproximate = isApproximate
        _jointOverrides = State(initialValue: initialJointOverrides)
        _hasEditedPose = State(initialValue: initialJointOverrides != nil)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ReconstructionSceneView(wallAnchors: wallAnchors, wallTextureReference: wallTextureReference, poseSample: poseSample, cameraTransform: cameraTransform, depthContext: depthContext, leftGrip: leftGrip, rightGrip: rightGrip, leftFoot: leftFoot, rightFoot: rightFoot, isEditingPose: isEditingPose, jointOverrides: $jointOverrides, draggedJoint: $draggedJoint, hasEditedPose: $hasEditedPose, initialWorldPositions: initialWorldPositions)
                .ignoresSafeArea()
                .allowsHitTesting(!isAnnotating)

            if isAnnotating {
                AnnotationOverlay(state: annotationState)
                    .ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let onBack {
                        Button(action: onBack) {
                            Label("Back to video", systemImage: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                    }
                    if let onFinished {
                        Button(action: onFinished) {
                            Label("Done", systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    modeControls
                }
                Text("Step 4 — Static 3D Reconstruction").font(.headline)
                if isApproximate {
                    Label("Estimated placement — no LiDAR depth for this moment, so this uses Vision's own estimate and the wall's saved camera position. Less precise than a live-generated view; hand grips aren't classified.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                // No climber detected in this frame — no longer a blocking error. Checking the
                // wall scan / camera angle / texture mapping in isolation (no body needed at all)
                // is a normal, useful thing to do on its own, so this just informs rather than
                // stopping the coach from viewing the wall reconstruction.
                if let poseError {
                    Label("No climber detected in this frame — showing wall only. \(poseError)", systemImage: "person.fill.questionmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isEditingPose {
                    Text("Drag a joint to correct it — connected limbs move with it, and movement is limited to roughly what a real joint allows.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if isAnnotating {
                    Text("Draw on the view to mark it up — pen, line, and angle tools below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("One-finger drag to orbit • two-finger drag to pan • pinch to zoom. Single static frame — no animation or playback.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if (poseSample != nil || initialWorldPositions != nil), !isEditingPose, !isAnnotating {
                    classificationSummary
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()

            if isAnnotating {
                AnnotationToolbar(state: annotationState)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .onAppear {
            if !initialAnnotationStrokes.isEmpty {
                annotationState.load(strokes: initialAnnotationStrokes)
            }
        }
        .onChange(of: annotationState.strokes) { _, newValue in
            onAnnotationStrokesChanged?(newValue)
        }
        .onChange(of: jointOverrides) { _, newValue in
            onJointOverridesChanged?(newValue)
        }
    }

    /// Mode-switch buttons — view/orbit (default), edit-pose, and annotate are mutually
    /// exclusive, since their gestures would otherwise fight over the same one-finger drag.
    /// Tapping a mode again turns it off (back to plain view/orbit).
    private var modeControls: some View {
        HStack(spacing: 8) {
            if hasEditedPose {
                Button("Reset Pose") {
                    jointOverrides = nil
                    hasEditedPose = false
                    draggedJoint = nil
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
            Button {
                isAnnotating = false
                isEditingPose.toggle()
            } label: {
                Label("Edit Pose", systemImage: "hand.draw")
            }
            .buttonStyle(.bordered)
            .tint(isEditingPose ? .green : nil)
            .font(.footnote)

            Button {
                isEditingPose = false
                isAnnotating.toggle()
            } label: {
                Label("Annotate", systemImage: "pencil.tip")
            }
            .buttonStyle(.bordered)
            .tint(isAnnotating ? .orange : nil)
            .font(.footnote)
        }
    }

    /// Per-limb grip/foot-placement readout — see `GripClassifier`. A confident classification
    /// shows the preset name + confidence in teal (matching the preset pose's render color); a
    /// nil-or-low-confidence one shows "uncertain" in orange (matching the same "not confident"
    /// color used elsewhere in this app, e.g. the tracking-quality cue) — a visible "not sure"
    /// instead of a confident-looking wrong guess, per the feature's required fallback behavior.
    private var classificationSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            classificationLine(label: "Left hand", name: leftGrip?.type.displayName, confidence: leftGrip?.confidence, offset: leftGripOffsetSeconds)
            classificationLine(label: "Right hand", name: rightGrip?.type.displayName, confidence: rightGrip?.confidence, offset: rightGripOffsetSeconds)
            classificationLine(label: "Left foot", name: leftFoot?.type.displayName, confidence: leftFoot?.confidence, offset: leftFootOffsetSeconds)
            classificationLine(label: "Right foot", name: rightFoot?.type.displayName, confidence: rightFoot?.confidence, offset: rightFootOffsetSeconds)
        }
        .font(.footnote)
    }

    private func classificationLine(label: String, name: String?, confidence: Float?, offset: TimeInterval?) -> some View {
        let isConfident = (confidence ?? 0) >= GripClassifier.confidenceThreshold
        return HStack(spacing: 4) {
            Text("\(label):").foregroundStyle(.secondary)
            if isConfident, let name, let confidence {
                Text("\(name) (\(Int(confidence * 100))%)").foregroundStyle(.teal)
            } else {
                Text("uncertain").foregroundStyle(.orange)
            }
            if let offset {
                Text(String(format: "· est. %.1fs %@", abs(offset), offset < 0 ? "earlier" : "later"))
                    .foregroundStyle(.orange)
            }
        }
    }
}

// `ReconstructionSceneView` (the RealityKit UIViewRepresentable rendering component + its
// gesture-handling `Coordinator`) has moved to
// Features/Reconstruction/Components/ReconstructionSceneView.swift — a large, self-contained
// rendering component this page just instantiates and binds to, not part of this page's own
// layout code.

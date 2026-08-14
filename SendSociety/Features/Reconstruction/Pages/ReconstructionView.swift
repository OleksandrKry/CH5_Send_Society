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
    let poseError: String?
    var onBack: (() -> Void)? = nil
    /// Called when the coach explicitly says they're done with this whole recording (shown as a
    /// "Done" button) — the caller's job is to return to `LibraryView`. Distinct from `onBack`
    /// (which goes back to Step 3's scrubber to pick a different moment): "Done" ends the pipeline
    /// run entirely, while "Back to video" stays within it.
    var onFinished: (() -> Void)? = nil
    /// Deletes this exact saved reconstruction and dismisses the view — nil (the default) means
    /// "don't show a delete option at all," which is the right default for a freshly-generated
    /// live Step 4 view that hasn't necessarily been saved yet. `SavedReconstructionReviewView`
    /// (session review's "already generated" path) supplies this, since that's the case a coach
    /// actually wants to clear a bad test result and retest — see its doc comment.
    var onDelete: (() -> Void)? = nil
    /// Previously-saved 3D-view annotations for this exact reconstruction, if this screen was
    /// reopened from a saved `ReconstructionRecord` (see `Core/Persistence`) rather than freshly
    /// generated — preloaded into `annotationState` on appear. Empty for a brand-new generation.
    var initialAnnotationStrokes: [AnnotationStrokeModel] = []
    /// Called whenever the coach's 3D-view annotations change (add/undo/clear), so the caller can
    /// persist them back into the session — nil (the default) means "don't bother," e.g. for a
    /// reconstruction that was never saved in the first place.
    var onAnnotationStrokesChanged: (([AnnotationStrokeModel]) -> Void)? = nil
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
    /// Gates the destructive `onDelete` action behind a confirmation — deleting overwrites the
    /// saved JSON blob with no undo, so this always confirms rather than deleting on first tap.
    @State private var isConfirmingDelete = false

    init(
        wallAnchors: [ARMeshAnchor],
        wallTextureReference: ARSessionManager.WallTextureReference?,
        poseSample: BodyPoseSample?,
        cameraTransform: simd_float4x4?,
        depthContext: BodyPose3DExtractor.DepthGroundingContext?,
        poseError: String?,
        onBack: (() -> Void)? = nil,
        onFinished: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        initialAnnotationStrokes: [AnnotationStrokeModel] = [],
        onAnnotationStrokesChanged: (([AnnotationStrokeModel]) -> Void)? = nil,
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
        self.poseError = poseError
        self.onBack = onBack
        self.onFinished = onFinished
        self.onDelete = onDelete
        self.initialAnnotationStrokes = initialAnnotationStrokes
        self.onAnnotationStrokesChanged = onAnnotationStrokesChanged
        self.initialWorldPositions = initialWorldPositions
        self.initialJointOverrides = initialJointOverrides
        self.onJointOverridesChanged = onJointOverridesChanged
        self.isApproximate = isApproximate
        _jointOverrides = State(initialValue: initialJointOverrides)
        _hasEditedPose = State(initialValue: initialJointOverrides != nil)
    }

    // THIS FILE IS UI ONLY — the joint-drag gesture state machine, camera orbit/pan/zoom, and
    // RealityKit rendering all live in `ReconstructionSceneView` (a `UIViewRepresentable` +
    // `Coordinator`, which is already its own self-contained "engine" for that gesture surface —
    // not duplicated or re-wrapped here). This page just holds simple toggle state (which mode is
    // active, whether annotating) and forwards it down via bindings/callbacks. Redesigning the
    // header/banners/buttons only requires editing this file; the 3D scene itself is a separate
    // component you compose into whatever new layout you build.

    var body: some View {
        ZStack(alignment: .top) {
            sceneArea
            if isAnnotating {
                AnnotationComponent(annotationState: annotationState)
                    .ignoresSafeArea()
            }
            headerPanel
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
        .confirmationDialog(
            "Delete this 3D reconstruction?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved 3D position for this moment so you can generate it again. This can't be undone.")
        }
    }

    // MARK: - The 3D scene itself (wall + skeleton, orbit/pan/zoom, joint editing)

    private var sceneArea: some View {
        ReconstructionSceneView(wallAnchors: wallAnchors, wallTextureReference: wallTextureReference, poseSample: poseSample, cameraTransform: cameraTransform, depthContext: depthContext, isEditingPose: isEditingPose, jointOverrides: $jointOverrides, draggedJoint: $draggedJoint, hasEditedPose: $hasEditedPose, initialWorldPositions: initialWorldPositions)
            .ignoresSafeArea()
            .allowsHitTesting(!isAnnotating)
    }

    // MARK: - Top overlay panel: back/done/delete buttons, mode controls, status text

    private var headerPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            topButtonRow
            Text("Step 4 — Static 3D Reconstruction").font(.headline)
            if isApproximate {
                approximatePlacementBanner
            }
            if let poseError {
                noClimberDetectedBanner(poseError)
            }
            modeInstructions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private var topButtonRow: some View {
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
            if onDelete != nil {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            Spacer()
            modeControls
        }
    }

    private var approximatePlacementBanner: some View {
        Label("Estimated placement — no LiDAR depth for this moment, so this uses Vision's own estimate and the wall's saved camera position. Less precise than a live-generated view.", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    // No climber detected in this frame — no longer a blocking error. Checking the wall scan /
    // camera angle / texture mapping in isolation (no body needed at all) is a normal, useful
    // thing to do on its own, so this just informs rather than stopping the coach from viewing
    // the wall reconstruction.
    private func noClimberDetectedBanner(_ poseError: String) -> some View {
        Label("No climber detected in this frame — showing wall only. \(poseError)", systemImage: "person.fill.questionmark")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Short instructions that change depending on which mode is active — editing a pose,
    /// drawing, or plain view/orbit.
    private var modeInstructions: some View {
        Group {
            if isEditingPose {
                Text("Tap a joint to select it — the camera locks and the joint highlights. Drag near it to correct it (connected limbs move with it, limited to roughly what a real joint allows). Tap elsewhere to finish, or tap another joint to switch.")
            } else if isAnnotating {
                Text("Draw on the view to mark it up — pen, line, and angle tools below.")
            } else {
                Text("One-finger drag to orbit • two-finger drag to pan • pinch to zoom. Single static frame — no animation or playback.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    /// Mode-switch buttons — view/orbit (default), edit-pose, and annotate are mutually
    /// exclusive, since their gestures would otherwise fight over the same one-finger drag.
    /// Tapping a mode again turns it off (back to plain view/orbit).
    private var modeControls: some View {
        HStack(spacing: 8) {
            if hasEditedPose {
                resetPoseButton
            }
            editPoseButton
            annotateButton
        }
    }

    private var resetPoseButton: some View {
        Button("Reset Pose") {
            jointOverrides = nil
            hasEditedPose = false
            draggedJoint = nil
        }
        .buttonStyle(.bordered)
        .font(.footnote)
    }

    private var editPoseButton: some View {
        Button {
            isAnnotating = false
            isEditingPose.toggle()
        } label: {
            Label("Edit Pose", systemImage: "hand.draw")
        }
        .buttonStyle(.bordered)
        .tint(isEditingPose ? .green : nil)
        .font(.footnote)
    }

    private var annotateButton: some View {
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

// `ReconstructionSceneView` (the RealityKit UIViewRepresentable rendering component + its
// gesture-handling `Coordinator`) has moved to
// Features/Reconstruction/Components/ReconstructionSceneView.swift — a large, self-contained
// rendering component this page just instantiates and binds to, not part of this page's own
// layout code.

// Preview note: no wall mesh/pose sample below, so the 3D view itself renders an empty scene
// (RealityKit content generally doesn't render live in Xcode's static canvas anyway) — this is
// mainly useful for checking the header/controls/banners layout without a live AR session.
#Preview {
    ReconstructionView(
        wallAnchors: [],
        wallTextureReference: nil,
        poseSample: nil,
        cameraTransform: nil,
        depthContext: nil,
        poseError: nil
    )
}

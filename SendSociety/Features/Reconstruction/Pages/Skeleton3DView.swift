//
//  3DSkeletonView.swift
//  SendSociety
//
//  Created by Christofer Theodore on 15/08/26.
//

import SwiftUI
import RealityKit
import ARKit
import simd

/// Step 4 — Generate the static 3D view. Non-AR RealityKit scene (no live camera passthrough):
/// the previously-scanned wall mesh + a single-frame skeleton, rendered together in the same
/// coordinate space, with one-finger drag-to-orbit. Static frame only — no animation, no
/// playback, no skeleton dragging (explicitly out of scope for this phase).
struct Skeleton3DView: View {
    let wallAnchors: [ARMeshAnchor]
    let wallTextureReference: ARSessionManager.WallTextureReference?
    let appleVisionSkeleton: AppleVisionSkeleton?
    let cameraTransform: simd_float4x4?
    let depthContext: AppleVisionSkeletonExtractor.DepthGroundingContext?
    let poseError: String?
    var onBack: (() -> Void)? = nil
    var onFinished: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var initialAnnotationStrokes: [AnnotationStrokeModel] = []
    var onAnnotationStrokesChanged: (([AnnotationStrokeModel]) -> Void)? = nil
    var originalAppleVisionJoints: [BodyJointName: SIMD3<Float>]? = nil
    var modifiedAppleVisionJoints: [BodyJointName: SIMD3<Float>]? = nil
    var onModifiedAppleVisionJoints: (([BodyJointName: SIMD3<Float>]?) -> Void)? = nil
    var isApproximate: Bool = false
    @State private var commitTrigger = SceneCommitTrigger()
    
    @State private var jointOverrides: [BodyJointName: SIMD3<Float>]?
    @State private var draggedJoint: BodyJointName? = nil
    @State private var hasEditedPose: Bool
    @StateObject private var annotationState = AnnotationState()
    /// Gates the destructive `onDelete` action behind a confirmation — deleting overwrites the
    /// saved JSON blob with no undo, so this always confirms rather than deleting on first tap.
    @State private var isConfirmingDelete = false
    @State private var isConfirmingReset = false
    
    @State private var lastKnownSavedAnnotationStrokes: [AnnotationStrokeModel] = []
    
    enum SkeletonInteractionMode {
        case camera      // default: orbit/pan the 3D view
        case editPose     // dragging joints
        case annotate     // drawing strokes
    }

    @State private var interactionMode: SkeletonInteractionMode = .camera
    private var isEditingPose: Bool {
        get { interactionMode == .editPose }
    }

    private var isUserDrawingBinding: Binding<Bool> {
        Binding(
            get: { interactionMode == .annotate },
            set: { interactionMode = $0 ? .annotate : .camera }
        )
    }
    
    private var isUserDrawing: Bool { interactionMode == .annotate }
    
    init(
        wallAnchors: [ARMeshAnchor],
        wallTextureReference: ARSessionManager.WallTextureReference?,
        appleVisionSkeleton: AppleVisionSkeleton?,
        cameraTransform: simd_float4x4?,
        depthContext: AppleVisionSkeletonExtractor.DepthGroundingContext?,
        poseError: String?,
        onBack: (() -> Void)? = nil,
        onFinished: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        initialAnnotationStrokes: [AnnotationStrokeModel] = [],
        onAnnotationStrokesChanged: (([AnnotationStrokeModel]) -> Void)? = nil,
        originalAppleVisionJoints: [BodyJointName: SIMD3<Float>]? = nil,
        modifiedAppleVisionJoints: [BodyJointName: SIMD3<Float>]? = nil,
        onModifiedAppleVisionJoints: (([BodyJointName: SIMD3<Float>]?) -> Void)? = nil,
        isApproximate: Bool = false
    ) {
        self.wallAnchors = wallAnchors
        self.wallTextureReference = wallTextureReference
        self.appleVisionSkeleton = appleVisionSkeleton
        self.cameraTransform = cameraTransform
        self.depthContext = depthContext
        self.poseError = poseError
        self.onBack = onBack
        self.onFinished = onFinished
        self.onDelete = onDelete
        self.initialAnnotationStrokes = initialAnnotationStrokes
        self.onAnnotationStrokesChanged = onAnnotationStrokesChanged
        self.originalAppleVisionJoints = originalAppleVisionJoints
        self.modifiedAppleVisionJoints = modifiedAppleVisionJoints
        self.onModifiedAppleVisionJoints = onModifiedAppleVisionJoints
        self.isApproximate = isApproximate
        _jointOverrides = State(initialValue: modifiedAppleVisionJoints)
        _hasEditedPose = State(initialValue: modifiedAppleVisionJoints != nil)
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
            if interactionMode == .annotate {
                AnnotationComponent(annotationState: annotationState).ignoresSafeArea()
            } else if !annotationState.strokes.isEmpty {
                AnnotationComponent(annotationState: annotationState, isInteractive: false).ignoresSafeArea()
            }
            headerPanel
        }
        .overlay(alignment: .bottomTrailing) {
            if (interactionMode != .editPose) {
                AnnotateToolbar(annotationState: annotationState, isUserDrawing: isUserDrawingBinding)
                .padding(.bottom, 70)
                .padding(.trailing, 70)
            }
            
        }
        .onAppear {
            if !initialAnnotationStrokes.isEmpty {
                lastKnownSavedAnnotationStrokes = initialAnnotationStrokes
                annotationState.load(strokes: initialAnnotationStrokes)
            }
        }
        .onChange(of: annotationState.strokes) { _, newValue in
            guard newValue != lastKnownSavedAnnotationStrokes else { return }
            lastKnownSavedAnnotationStrokes = newValue
            onAnnotationStrokesChanged?(newValue)
            
        }
        .onChange(of: jointOverrides) { _, newValue in
            onModifiedAppleVisionJoints?(newValue)
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
        .confirmationDialog(
            "Reset this pose?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                commitTrigger.commit?()
                jointOverrides = nil
                hasEditedPose = false
                draggedJoint = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This discards any manual joint corrections you've made and reverts to the auto-detected pose. This can't be undone.")
        }
    }

    // MARK: - The 3D scene itself (wall + skeleton, orbit/pan/zoom, joint editing)

    private var sceneArea: some View {
        Skeleton3DSceneView(wallAnchors: wallAnchors, wallTextureReference: wallTextureReference, appleVisionSkeleton: appleVisionSkeleton, cameraTransform: cameraTransform, depthContext: depthContext, isEditingPose: isEditingPose, jointOverrides: $jointOverrides, draggedJoint: $draggedJoint, hasEditedPose: $hasEditedPose, originalAppleVisionJoints: originalAppleVisionJoints,
            commitTrigger: commitTrigger)
            .ignoresSafeArea()
    }

    // MARK: - Top overlay panel: back/done/delete buttons, mode controls, status text

    private var headerPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            topButtonRow
//            Text("Step 4 — Static 3D Reconstruction").font(.headline)
//            if isApproximate {
//                approximatePlacementBanner
//            }
//            if let poseError {
//                noClimberDetectedBanner(poseError)
//            }
//            modeInstructions
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private var topButtonRow: some View {
        HStack {
            if isEditingPose {
                Spacer()
                resetPoseButton
                doneEditingPoseButton
            } else {
                if let onBack {
                    Button {
                        commitTrigger.commit?()
                        onBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                }
                if onDelete != nil {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete Visualization", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                Spacer()
                editPoseButton
            }
        }
    }
    
    private var doneEditingPoseButton: some View {
        Button {
            commitTrigger.commit?()
            interactionMode = .camera
        } label: {
            Label("Done", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
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
            if interactionMode == .editPose {
                Text("Tap a joint to select it — the camera locks and the joint highlights. Drag near it to correct it (connected limbs move with it, limited to roughly what a real joint allows). Tap elsewhere to finish, or tap another joint to switch.")
            } else if interactionMode == .annotate {
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
            
        }
    }

    private var resetPoseButton: some View {
        Button {
            isConfirmingReset = true
        } label: {
            Label("Reset Pose", systemImage: "arrow.trianglehead.2.counterclockwise.rotate.90")
        }
        .buttonStyle(.bordered)
    }

    private var editPoseButton: some View {
        Button {
            interactionMode = .editPose
        } label: {
            Label("Edit Pose", systemImage: "move.3d")
        }
        .buttonStyle(.bordered)
    }
    
}

#Preview {
    Skeleton3DView(
        wallAnchors: [],
        wallTextureReference: nil,
        appleVisionSkeleton: nil,
        cameraTransform: nil,
        depthContext: nil,
        poseError: nil
    )
}

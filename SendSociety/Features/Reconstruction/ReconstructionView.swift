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
    let cameraTransform: simd_float4x4
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

    var body: some View {
        ZStack(alignment: .top) {
            ReconstructionSceneView(wallAnchors: wallAnchors, wallTextureReference: wallTextureReference, poseSample: poseSample, cameraTransform: cameraTransform, depthContext: depthContext, leftGrip: leftGrip, rightGrip: rightGrip, leftFoot: leftFoot, rightFoot: rightFoot)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let onBack {
                        Button(action: onBack) {
                            Label("Back to video", systemImage: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                }
                Text("Step 4 — Static 3D Reconstruction").font(.headline)
                Text("One-finger drag to orbit • two-finger drag to pan • pinch to zoom. Single static frame — no animation or playback.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if poseSample != nil {
                    classificationSummary
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()

            // Climbing-action frames are much harder for Vision to detect a clean body pose in
            // than the calibration T-pose (motion blur, self-occlusion, limbs against the wall).
            // Make a failed detection impossible to miss, and let the coach immediately go back
            // and try a different paused moment instead of staring at a wall with no climber.
            if let poseError {
                VStack(spacing: 12) {
                    Label("No climber body in this frame", systemImage: "person.fill.questionmark")
                        .font(.headline)
                    Text(poseError)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if let onBack {
                        Button("Pick a different moment", action: onBack)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .frame(maxWidth: 360)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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

private struct ReconstructionSceneView: UIViewRepresentable {
    let wallAnchors: [ARMeshAnchor]
    let wallTextureReference: ARSessionManager.WallTextureReference?
    let poseSample: BodyPoseSample?
    let cameraTransform: simd_float4x4
    let depthContext: BodyPose3DExtractor.DepthGroundingContext?
    let leftGrip: GripClassification?
    let rightGrip: GripClassification?
    let leftFoot: FootClassification?
    let rightFoot: FootClassification?

    func makeUIView(context: Context) -> ARView {
        // cameraMode: .nonAR — a plain 3D scene, not a live camera-passthrough AR view.
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        // Neutral light gray instead of pure black — reads as a lit room rather than a void.
        view.environment.background = .color(UIColor(white: 0.85, alpha: 1.0))

        let contentAnchor = AnchorEntity(world: .zero)
        contentAnchor.addChild(ReconstructionEntityBuilder.wallEntity(from: wallAnchors, textureReference: wallTextureReference))
        if let poseSample {
            contentAnchor.addChild(ReconstructionEntityBuilder.skeletonEntity(from: poseSample, cameraTransform: cameraTransform, depthContext: depthContext, wallReference: wallTextureReference, leftGrip: leftGrip, rightGrip: rightGrip, leftFoot: leftFoot, rightFoot: rightFoot))
        }
        view.scene.addAnchor(contentAnchor)

        // The wall's material is a lit SimpleMaterial now (not unlit), so it needs an actual
        // light in the scene or it renders flat black. A single angled directional light with
        // shadows is enough to reveal hold bumps/wall contour via shading.
        let lightAnchor = AnchorEntity(world: .zero)
        let light = DirectionalLight()
        var lightComponent = DirectionalLightComponent()
        lightComponent.color = .white
        lightComponent.intensity = 4000
        light.light = lightComponent
        light.shadow = DirectionalLightComponent.Shadow()
        light.look(at: .zero, from: SIMD3<Float>(1.5, 2.5, 1.5), relativeTo: nil)
        lightAnchor.addChild(light)
        view.scene.addAnchor(lightAnchor)

        let cameraEntity = PerspectiveCamera()
        cameraEntity.camera.fieldOfViewInDegrees = 60
        let cameraAnchor = AnchorEntity(world: .zero)
        cameraAnchor.addChild(cameraEntity)
        view.scene.addAnchor(cameraAnchor)

        let skeletonPositions = poseSample.map {
            ReconstructionEntityBuilder.worldJointPositions(from: $0, cameraTransform: cameraTransform, depthContext: depthContext, wallReference: wallTextureReference)
        } ?? [:]
        let framing = Self.framing(wallAnchors: wallAnchors, skeletonPositions: Array(skeletonPositions.values))

        context.coordinator.cameraEntity = cameraEntity
        context.coordinator.orbitCenter = framing.center
        context.coordinator.radius = framing.radius
        context.coordinator.minRadius = max(framing.radius * 0.15, 0.3)
        context.coordinator.maxRadius = framing.radius * 4
        // Start looking at the wall from roughly the SAME side the Step 1 reference photo was
        // taken from — the side the texture/UVs are keyed to, i.e. the only side that reads
        // right-way-round instead of mirrored (the mesh is a thin single sheet with culling
        // disabled, so it's visible-but-backwards from the far side). Without this, the default
        // view could easily start on the wrong side, showing mirrored wall text AND making the
        // skeleton look like it's embedded in/behind the wall purely because of which way the
        // camera happens to be facing.
        context.coordinator.azimuth = Self.initialAzimuth(center: framing.center, wallTextureReference: wallTextureReference)
        context.coordinator.updateCameraTransform()

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        // Cap at 1 finger so this doesn't fight the two-finger pan gesture below for the same
        // drag — without this, a two-finger touch would also register as a (very fast, jittery)
        // one-finger rotate.
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        // Two-finger drag = pan (translate the view), one-finger = rotate, pinch = zoom — the
        // exact gesture set SceneKit's `allowsCameraControl` and AR Quick Look's "Object mode"
        // use, so it matches muscle memory the coach already has from ordinary iOS use.
        // Deliberately NOT adding two-finger twist-to-roll: the wall is always upright, so
        // rolling the camera relative to it has no useful purpose here and would just make it
        // easy to get disoriented.
        let twoFingerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(twoFingerPan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Centers and sizes the initial orbit view around BOTH the wall mesh and the climber's
    /// skeleton (if detected), so the coach doesn't land on a view where the body is off-frame
    /// or a tiny speck relative to the wall.
    private static func framing(wallAnchors: [ARMeshAnchor], skeletonPositions: [SIMD3<Float>]) -> (center: SIMD3<Float>, radius: Float) {
        var points = wallAnchors.map { anchor -> SIMD3<Float> in
            let t = anchor.transform.columns.3
            return SIMD3<Float>(t.x, t.y, t.z)
        }
        points.append(contentsOf: skeletonPositions)
        guard !points.isEmpty else { return (.zero, 2.5) }

        let center = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        let maxDistance = points.reduce(Float(0)) { max($0, simd_distance($1, center)) }
        // Pad so content isn't touching the frame edge; clamp to a sane range.
        let radius = min(max(maxDistance * 2.2, 1.5), 12.0)
        return (center, radius)
    }

    /// Azimuth (radians) that points the initial orbit camera toward `center` from roughly the
    /// same direction the wall reference photo was taken from — see the call site's comment for
    /// why. Falls back to 0 (this view's previous fixed default) if there's no reference frame or
    /// it's degenerate (directly above/below the center, where azimuth is meaningless).
    private static func initialAzimuth(center: SIMD3<Float>, wallTextureReference: ARSessionManager.WallTextureReference?) -> Float {
        guard let wallTextureReference else { return 0 }
        let refColumn = wallTextureReference.cameraTransform.columns.3
        let refPosition = SIMD3<Float>(refColumn.x, refColumn.y, refColumn.z)
        let toReference = refPosition - center
        let horizontal = SIMD2<Float>(toReference.x, toReference.z)
        guard simd_length(horizontal) > 0.01 else { return 0 }
        return atan2(horizontal.x, horizontal.y)
    }

    final class Coordinator: NSObject {
        weak var cameraEntity: PerspectiveCamera?
        var orbitCenter: SIMD3<Float> = .zero
        var azimuth: Float = 0
        var elevation: Float = 0.3
        var radius: Float = 2.5
        var minRadius: Float = 0.4
        var maxRadius: Float = 20.0

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            azimuth -= Float(translation.x) * 0.005
            elevation = max(-1.4, min(1.4, elevation - Float(translation.y) * 0.005))
            gesture.setTranslation(.zero, in: gesture.view)
            updateCameraTransform()
        }

        /// Pinch to zoom — shrinks/grows the orbit radius. Clamped so you can't zoom through the
        /// content or pinch out to a speck.
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.scale.isFinite, gesture.scale > 0 else { return }
            radius = min(max(radius / Float(gesture.scale), minRadius), maxRadius)
            gesture.scale = 1
            updateCameraTransform()
        }

        /// Two-finger drag — pans the orbit target across the camera's own local right/up plane
        /// (the camera itself always sits at `orbitCenter + spherical offset`, so moving the
        /// target moves the whole rig together). Sign convention: content follows the fingers,
        /// like dragging a photo — matching AR Quick Look's Object mode and SceneKit's
        /// `allowsCameraControl` two-finger pan.
        @objc func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard let cameraEntity else { return }
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)

            let orientation = cameraEntity.orientation(relativeTo: nil)
            let right = orientation.act(SIMD3<Float>(1, 0, 0))
            let up = orientation.act(SIMD3<Float>(0, 1, 0))

            // Scale by radius so the pan feels consistent whether zoomed in tight on a single
            // hold or zoomed out to see the whole wall — a fixed pixel-to-world ratio would feel
            // far too fast up close and barely move anything zoomed out.
            let panScale = radius * 0.0015
            orbitCenter += -right * Float(translation.x) * panScale + up * Float(translation.y) * panScale
            updateCameraTransform()
        }

        func updateCameraTransform() {
            guard let cameraEntity else { return }
            let x = orbitCenter.x + radius * cos(elevation) * sin(azimuth)
            let y = orbitCenter.y + radius * sin(elevation)
            let z = orbitCenter.z + radius * cos(elevation) * cos(azimuth)
            let position = SIMD3<Float>(x, y, z)
            cameraEntity.position = position
            cameraEntity.look(at: orbitCenter, from: position, relativeTo: nil)
        }
    }
}

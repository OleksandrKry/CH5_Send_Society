import SwiftUI
import RealityKit
import ARKit
import simd

/// The actual RealityKit rendering + gesture surface behind `ReconstructionView` — the non-AR
/// orbit-camera scene (wall mesh + skeleton), one-finger orbit / two-finger pan / pinch-zoom, and
/// (when `isEditingPose`) joint-drag hit-testing. Pulled into its own file since it's a large,
/// self-contained rendering component `ReconstructionView` just instantiates and binds to, not part
/// of that page's own layout code.
struct ReconstructionSceneView: UIViewRepresentable {
    let wallAnchors: [ARMeshAnchor]
    let wallTextureReference: ARSessionManager.WallTextureReference?
    let poseSample: BodyPoseSample?
    let cameraTransform: simd_float4x4?
    let depthContext: BodyPose3DExtractor.DepthGroundingContext?
    /// When true, a one-finger drag on a joint moves it (see `Coordinator`'s hit-testing); when
    /// false, one-finger drag always orbits, exactly as before this feature existed.
    let isEditingPose: Bool
    /// The coach's manually-edited pose, if any — nil means "show the auto-detected pose."
    /// Written by the Coordinator when a drag ends; set back to nil externally by "Reset Pose."
    @Binding var jointOverrides: [BodyJointName: SIMD3<Float>]?
    /// The joint currently SELECTED (tapped, camera-locked, highlighted), if any — set the moment
    /// a joint is tapped and cleared only when the coach taps outside its radius, NOT just while a
    /// drag is actively happening — see `Coordinator.handleJointTouch`'s doc comment for the full
    /// state machine. Read by `ReconstructionView` only for potential future UI (e.g. naming which
    /// joint is selected); not required for the core feature to work.
    @Binding var draggedJoint: BodyJointName?
    @Binding var hasEditedPose: Bool
    /// Already depth-grounded positions to use as the baseline instead of computing from
    /// `poseSample`/`depthContext` — a saved session review reopening a previously-generated
    /// reconstruction (see `ReconstructionView.initialWorldPositions`'s doc comment). nil for a
    /// brand-new "Generate" tap, preserving the original compute-from-poseSample behavior exactly.
    let initialWorldPositions: [BodyJointName: SIMD3<Float>]?

    func makeUIView(context: Context) -> ARView {
        // cameraMode: .nonAR — a plain 3D scene, not a live camera-passthrough AR view.
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        // Neutral light gray instead of pure black — reads as a lit room rather than a void.
        view.environment.background = .color(UIColor(white: 0.85, alpha: 1.0))
        context.coordinator.parent = self
        context.coordinator.arView = view

        let contentAnchor = AnchorEntity(world: .zero)
        contentAnchor.addChild(ReconstructionEntityBuilder.wallEntity(from: wallAnchors, textureReference: wallTextureReference))
        view.scene.addAnchor(contentAnchor)
        context.coordinator.contentAnchor = contentAnchor

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

        let skeletonPositions = initialWorldPositions ?? (poseSample.map {
            ReconstructionEntityBuilder.worldJointPositions(from: $0, cameraTransform: cameraTransform ?? matrix_identity_float4x4, depthContext: depthContext, wallReference: wallTextureReference)
        } ?? [:])

        // `originalPositions` is the auto-detected baseline used both as the ROM constraints'
        // reference direction (see SkeletonPoseEditor) and as what "Reset Pose" reverts to.
        // `currentPositions` starts identical to it and only diverges once the coach drags
        // something. `jointOverrides` (if the coach already edited this pose, then navigated away
        // and back) takes priority so re-entering this screen doesn't silently discard an edit.
        context.coordinator.originalPositions = skeletonPositions
        context.coordinator.currentPositions = jointOverrides ?? skeletonPositions

        context.coordinator.cameraEntity = cameraEntity

        // Seed the initial camera from the ACTUAL recording position/angle for this frame when one
        // is available (`cameraTransform` is only non-nil for a freshly-generated, live frame —
        // see its doc comment), instead of a generic bounding-box heuristic. This is what makes
        // the starting zoom/angle match the real recording distance/angle rather than reading as
        // "too far away" or "too flat" — ported from the CH5_Lidar_Testing sibling project's
        // `Scene3DView`, which validated this exact technique on device.
        if let cameraTransform, let seed = Self.cameraSeedFraming(recordingCameraTransform: cameraTransform, depthContext: depthContext, wallAnchors: wallAnchors) {
            context.coordinator.orbitCenter = seed.target
            context.coordinator.radius = seed.radius
            context.coordinator.minRadius = max(seed.radius * 0.15, 0.05)
            context.coordinator.maxRadius = max(seed.radius * 8, 4)
            context.coordinator.elevation = seed.elevation
            context.coordinator.azimuth = seed.azimuth
            DebugLog.reconstruction.info("3D view camera seeded from real recording transform — distance to surface=\(seed.radius, privacy: .public)m")
        } else {
            // No real per-frame camera transform (a loaded/reviewed reconstruction) — fall back to
            // the old bounding-box-based framing.
            let framing = Self.framing(wallAnchors: wallAnchors, skeletonPositions: Array(skeletonPositions.values))
            context.coordinator.orbitCenter = framing.center
            context.coordinator.radius = framing.radius
            context.coordinator.minRadius = max(framing.radius * 0.15, 0.3)
            context.coordinator.maxRadius = framing.radius * 4
            context.coordinator.elevation = 0.3
            // Start looking at the wall from roughly the SAME side the Step 1 reference photo was
            // taken from — the side the texture/UVs are keyed to, i.e. the only side that reads
            // right-way-round instead of mirrored (the mesh is a thin single sheet with culling
            // disabled, so it's visible-but-backwards from the far side). Without this, the default
            // view could easily start on the wrong side, showing mirrored wall text AND making the
            // skeleton look like it's embedded in/behind the wall purely because of which way the
            // camera happens to be facing.
            context.coordinator.azimuth = Self.initialAzimuth(center: framing.center, wallTextureReference: wallTextureReference)
        }
        context.coordinator.updateCameraTransform()

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        // Cap at 1 finger so this doesn't fight the two-finger pan gesture below for the same
        // drag — without this, a two-finger touch would also register as a (very fast, jittery)
        // one-finger rotate.
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        // Drives the tap-to-select / drag-within-radius / tap-outside-to-finish joint editing
        // state machine — see `Coordinator.handleJointTouch`'s doc comment for why this needs to
        // be a `UILongPressGestureRecognizer` with zero minimum duration rather than reusing
        // `pan` above: a plain tap (finger down, then up, with no movement) never crosses
        // `UIPanGestureRecognizer`'s own movement threshold, so it would never even report
        // `.began` — this recognizer reports `.began` the instant the finger touches down,
        // capturing a pure tap AND a drag through the same callback. Only claims touches while
        // `isEditingPose` is true (see `gestureRecognizerShouldBegin`) — `pan` above handles
        // ordinary orbiting the rest of the time, unchanged.
        let jointTouch = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleJointTouch(_:)))
        jointTouch.minimumPressDuration = 0
        jointTouch.delegate = context.coordinator
        view.addGestureRecognizer(jointTouch)

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

        // Builds the initial skeleton entity through the SAME path every later rebuild (drag
        // start/change/end, external reset) goes through, so there's exactly one place that knows
        // how to turn "current joint positions + highlight state" into the rendered entity.
        context.coordinator.rebuildSkeleton()

        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.parent = self
        // External reset (the "Reset Pose" button) sets `jointOverrides` back to nil — the
        // Coordinator's own internal edits never do that themselves (see `endJointDrag`), so
        // seeing nil here while the Coordinator still thinks it has an edited pose unambiguously
        // means "the coach asked to revert," not "no edit has happened yet." `resetToOriginal`
        // already rebuilds, so return rather than rebuilding a second time below.
        if jointOverrides == nil, context.coordinator.hasAppliedOverride {
            context.coordinator.resetToOriginal()
            return
        }
        // Covers every other reason SwiftUI re-evaluated this view — most notably toggling Edit
        // Pose on/off, which needs to show/hide the mannequin body (`hideMannequinBody`) right
        // away. Cheap enough to just always do (this only runs on discrete UI events, never per
        // drag-frame — mid-drag updates go straight through the Coordinator, bypassing SwiftUI).
        context.coordinator.rebuildSkeleton()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Seeds the initial orbit camera from the REAL recording position/angle for this frame,
    /// instead of a generic bounding-box heuristic — this is what makes the starting zoom/angle
    /// actually match the video, rather than reading as "too far away" or "too flat."
    ///
    /// `recordingCameraTransform` MUST be this exact frame's own ARKit camera pose (not a
    /// different frame's, and not a placeholder identity) — see `cameraTransform`'s doc comment.
    /// Finds the real surface point that camera was looking at two ways, most-precise first:
    /// 1. `centerDepthMeters` — this exact frame's own depth grid, read straight ahead. Precise,
    ///    since it's a real per-pixel LiDAR measurement for the SAME moment being reconstructed.
    /// 2. `surfacePoint` — a nearest-mesh-vertex raycast against the scanned wall, for when this
    ///    specific frame has no depth data (e.g. past `RecordedFrameStore`'s cap) but the wall scan
    ///    still exists.
    /// Returns nil if neither works (e.g. no depth AND no wall scan at all), so the caller can fall
    /// back to `framing`'s cruder bounding-box approach.
    ///
    /// Once a real target point is found, `radius`/`elevation`/`azimuth` all come from ONE
    /// coherent vector — the offset from that surface point back to the camera — exactly mirroring
    /// the CH5_Lidar_Testing sibling project's `Scene3DView`, which validated this on real
    /// hardware. The previous version computed azimuth from a DIFFERENT reference point (the Step
    /// 1 wall-scan camera) than radius/center (a crude multi-point average) — two unrelated
    /// numbers that happened to both feed the same camera, which is part of why the result didn't
    /// track the real recording angle.
    private static func cameraSeedFraming(
        recordingCameraTransform: simd_float4x4,
        depthContext: BodyPose3DExtractor.DepthGroundingContext?,
        wallAnchors: [ARMeshAnchor]
    ) -> (target: SIMD3<Float>, radius: Float, elevation: Float, azimuth: Float)? {
        let column = recordingCameraTransform.columns.3
        let position = SIMD3<Float>(column.x, column.y, column.z)
        let forward4 = recordingCameraTransform * SIMD4<Float>(0, 0, -1, 0)
        let forward = SIMD3<Float>(forward4.x, forward4.y, forward4.z)

        var target: SIMD3<Float>?
        if let depthContext, let distance = ReconstructionEntityBuilder.centerDepthMeters(from: depthContext) {
            target = position + forward * distance
        }
        if target == nil {
            target = ReconstructionEntityBuilder.surfacePoint(nearRayFrom: position, direction: forward, in: wallAnchors)
        }
        guard let target else { return nil }

        // Pull back a bit (×1.5) so the initial view isn't so tight it reads as MORE zoomed-in
        // than the actual recording — same tuning validated in CH5_Lidar_Testing.
        let offset = (position - target) * 1.5
        let r = max(simd_length(offset), 0.05)
        let elevation = max(-1.4, min(1.4, asin(min(max(offset.y / r, -1), 1))))
        let horizontal = SIMD2<Float>(offset.x, offset.z)
        let azimuth = simd_length(horizontal) > 0.001 ? atan2(horizontal.x, horizontal.y) : 0
        return (target, r, elevation, azimuth)
    }

    /// Centers and sizes the initial orbit view around BOTH the wall mesh and the climber's
    /// skeleton (if detected), so the coach doesn't land on a view where the body is off-frame
    /// or a tiny speck relative to the wall. FALLBACK ONLY — used when `cameraSeedFraming` can't
    /// find a real recording transform/surface point (see its doc comment).
    private static func framing(wallAnchors: [ARMeshAnchor], skeletonPositions: [SIMD3<Float>]) -> (center: SIMD3<Float>, radius: Float) {
        var points = wallAnchors.map { anchor -> SIMD3<Float> in
            let t = anchor.transform.columns.3
            return SIMD3<Float>(t.x, t.y, t.z)
        }
        points.append(contentsOf: skeletonPositions)
        guard !points.isEmpty else { return (.zero, 2.5) }

        let center = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        let maxDistance = points.reduce(Float(0)) { max($0, simd_distance($1, center)) }
        // Pad so content isn't touching the frame edge, then pull back further (×1.5) so the
        // initial view isn't so tight it reads as more zoomed-in than the actual video recording
        // angle — same tuning fix validated in the LidarCalibTest sibling project. Clamp to a sane
        // range afterward.
        let radius = min(max(maxDistance * 2.2, 1.5) * 1.5, 12.0)
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

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Reference back to the current SwiftUI struct instance — reassigned at the top of every
        /// `makeUIView`/`updateUIView` call, since SwiftUI creates a fresh `ReconstructionSceneView`
        /// value on every body re-evaluation. Standard UIViewRepresentable bridging pattern.
        var parent: ReconstructionSceneView
        weak var arView: ARView?
        weak var contentAnchor: AnchorEntity?
        private weak var skeletonEntityRef: Entity?

        weak var cameraEntity: PerspectiveCamera?
        var orbitCenter: SIMD3<Float> = .zero
        var azimuth: Float = 0
        var elevation: Float = 0.3
        var radius: Float = 2.5
        var minRadius: Float = 0.4
        var maxRadius: Float = 20.0

        /// The auto-detected baseline for this frame — used as the ROM constraints' reference
        /// direction and as what "Reset Pose" reverts to. Set once in `makeUIView`, never mutated
        /// afterward.
        var originalPositions: [BodyJointName: SIMD3<Float>] = [:]
        /// The live positions actually being rendered — starts equal to `originalPositions` and
        /// only diverges once the coach drags something.
        var currentPositions: [BodyJointName: SIMD3<Float>] = [:]
        /// The joint currently SELECTED — persists across separate touches once tapped (step 1 of
        /// the doc comment on `handleJointTouch`), unlike the old model where lifting the finger
        /// ended everything. Non-nil for the whole "camera locked, highlighted, waiting for either
        /// a drag-within-radius or a tap-outside-to-finish" session, not just while actively
        /// mid-drag.
        private var selectedJoint: BodyJointName?
        /// True only while a touch that started WITHIN `selectedJoint`'s radius is actively
        /// dragging it — distinct from merely having a joint selected (finger could be lifted, or
        /// resting down without having moved).
        private var isDraggingSelectedJoint = false
        /// World-space position of the dragged joint at the MOMENT the drag started — this fixes
        /// the depth-from-camera plane the touch point unprojects onto for the rest of the
        /// gesture (see `updateJointDrag`), so the plane doesn't chase the joint as it moves.
        private var dragPlaneAnchor: SIMD3<Float>?
        /// Screen location of the previous `.changed` callback while orbiting via `handleJointTouch`
        /// (edit mode, nothing selected yet) — `UILongPressGestureRecognizer` has no built-in
        /// translation the way `UIPanGestureRecognizer` does, so the frame-to-frame delta is
        /// tracked manually here.
        private var lastOrbitTouchLocation: CGPoint?
        /// Real-world radius (meters) around a joint's CURRENT position that counts as "close
        /// enough to grab" — see `screenRadius(for:in:)` for how this becomes a perspective-correct
        /// on-screen hit zone that shrinks/grows with zoom exactly like the joint's actual apparent
        /// size would, instead of a fixed pixel radius that would feel too generous zoomed out and
        /// too stingy zoomed in.
        private let jointSelectionRadius: Float = 0.08
        /// True once a drag has been committed back to `parent.jointOverrides` — lets
        /// `updateUIView` tell "coach tapped Reset Pose" (jointOverrides went nil while this is
        /// true) apart from "no edit has ever happened" (both nil, nothing to do).
        var hasAppliedOverride = false

        init(parent: ReconstructionSceneView) {
            self.parent = parent
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            // `handleJointTouch` below owns ALL of edit-mode's interaction, including orbiting
            // while nothing's selected — this recognizer is only for ordinary orbit outside edit
            // mode (see `gestureRecognizerShouldBegin`, which keeps `handleJointTouch` from even
            // claiming a touch while pose-editing is off).
            guard let view = gesture.view, !parent.isEditingPose else { return }
            let translation = gesture.translation(in: view)
            azimuth -= Float(translation.x) * 0.005
            elevation = max(-1.4, min(1.4, elevation - Float(translation.y) * 0.005))
            gesture.setTranslation(.zero, in: view)
            updateCameraTransform()
        }

        /// Only allows `handleJointTouch`'s recognizer to claim a touch while pose-editing is on —
        /// `pan` above handles ordinary orbiting the rest of the time. Swift's default behavior for
        /// two unrelated gesture recognizers on the same view is already mutually exclusive (first
        /// to recognize wins), so this is the only coordination needed between them.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            parent.isEditingPose
        }

        /// Drives the tap-to-select / drag-within-radius / tap-outside-to-finish joint editing
        /// state machine:
        /// 1. Tap a joint (touch down within its radius, no selection yet) -> selects it.
        /// 2. Selecting a joint locks the camera (orbit/pan/pinch all check `selectedJoint == nil`
        ///    — see `handlePinch`/`handleTwoFingerPan`, and the orbit branch below).
        /// 3. The selected joint stays highlighted for the whole selection, not just mid-drag (see
        ///    `rebuildSkeleton`'s `selectedJoint`-driven highlight).
        /// 4. A NEW touch that starts WITHIN the selected joint's radius drags it — the coach can
        ///    do several separate drags in a row on the same joint without it being deselected.
        /// 5. A touch OUTSIDE the selected joint's radius, landing on nothing else, finishes
        ///    editing (commits `currentPositions`, clears the highlight, unlocks the camera).
        /// 6. A touch OUTSIDE the selected joint's radius that instead lands within ANOTHER
        ///    joint's radius finishes the first one AND immediately re-enters step 1-3 for the new
        ///    joint, in one motion — no need for a separate deselect tap first.
        ///
        /// `UILongPressGestureRecognizer` with `minimumPressDuration = 0` (not
        /// `UITapGestureRecognizer` or `UIPanGestureRecognizer`) is what makes ONE recognizer
        /// report both a pure tap (`.began` immediately followed by `.ended`, no movement) and a
        /// drag (`.began`, then `.changed` as the finger moves, then `.ended`) — a plain
        /// `UIPanGestureRecognizer` only reports `.began` once the finger has already moved past
        /// its own minimum distance, which would silently miss a "tap with no drag at all" select.
        @objc func handleJointTouch(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                if let selected = selectedJoint {
                    if withinRadius(selected, at: location) {
                        beginJointDrag(joint: selected)
                    } else if let other = jointWithinRadius(at: location, excluding: selected) {
                        finishEditingSelectedJoint()
                        selectJoint(other)
                    } else {
                        finishEditingSelectedJoint()
                    }
                } else if let joint = jointWithinRadius(at: location) {
                    selectJoint(joint)
                } else {
                    lastOrbitTouchLocation = location
                }
            case .changed:
                if isDraggingSelectedJoint, let selected = selectedJoint {
                    updateJointDrag(joint: selected, screenLocation: location)
                } else if selectedJoint == nil, let last = lastOrbitTouchLocation {
                    let dx = Float(location.x - last.x)
                    let dy = Float(location.y - last.y)
                    azimuth -= dx * 0.005
                    elevation = max(-1.4, min(1.4, elevation - dy * 0.005))
                    lastOrbitTouchLocation = location
                    updateCameraTransform()
                }
                // Else: a joint IS selected but this isn't the drag touch (e.g. the finger is
                // resting inside the radius without having moved yet) — camera stays locked,
                // nothing to update.
            case .ended, .cancelled, .failed:
                if isDraggingSelectedJoint {
                    isDraggingSelectedJoint = false
                    dragPlaneAnchor = nil
                    // Selection itself is NOT cleared here — lifting the finger after a drag only
                    // ends THAT drag; the joint stays selected/highlighted/camera-locked until the
                    // coach taps outside its radius (step 5), so several small adjustments in a
                    // row don't each need a fresh tap-to-select first.
                }
                lastOrbitTouchLocation = nil
            default:
                break
            }
        }

        /// Screen-space hit radius for `joint` at ITS CURRENT distance from the camera — projects
        /// both the joint and a point `jointSelectionRadius` meters to its side, so the on-screen
        /// hit zone naturally shrinks/grows with zoom exactly like the joint's real 3D size would,
        /// rather than a fixed pixel radius that would feel too generous zoomed out and too stingy
        /// zoomed in. UNVERIFIED ON DEVICE: `ARView.project(_:)` is a real, documented RealityKit
        /// API (world point -> 2D view point) — https://developer.apple.com/documentation/realitykit/arview/project(_:)
        /// — same category of API as `ARView.ray(through:)` already used below.
        private func screenRadius(for joint: BodyJointName, in view: ARView) -> (center: CGPoint, radius: CGFloat)? {
            guard let cameraEntity, let worldPosition = currentPositions[joint],
                  let centerScreen = view.project(worldPosition)
            else { return nil }
            let right = cameraEntity.orientation(relativeTo: nil).act(SIMD3<Float>(1, 0, 0))
            let edgeWorld = worldPosition + right * jointSelectionRadius
            guard let edgeScreen = view.project(edgeWorld) else { return nil }
            let pixelRadius = hypot(edgeScreen.x - centerScreen.x, edgeScreen.y - centerScreen.y)
            // Floored at 24pt (roughly Apple HIG's minimum touch-target radius) so a joint that's
            // zoomed way out still has a tappable hit zone, not a sub-pixel target.
            return (centerScreen, max(24, pixelRadius))
        }

        /// Nearest joint whose radius (see `screenRadius`) contains `location`, if any — "nearest"
        /// so two overlapping radii (a zoomed-out view with several joints close together) resolve
        /// to a sensible single choice rather than dictionary-iteration order.
        private func jointWithinRadius(at location: CGPoint, excluding: BodyJointName? = nil) -> BodyJointName? {
            guard let arView else { return nil }
            var best: (joint: BodyJointName, distance: CGFloat)?
            for joint in currentPositions.keys where joint != excluding {
                guard let (center, radius) = screenRadius(for: joint, in: arView) else { continue }
                let distance = hypot(location.x - center.x, location.y - center.y)
                guard distance <= radius else { continue }
                if best == nil || distance < best!.distance {
                    best = (joint, distance)
                }
            }
            return best?.joint
        }

        private func withinRadius(_ joint: BodyJointName, at location: CGPoint) -> Bool {
            guard let arView, let (center, radius) = screenRadius(for: joint, in: arView) else { return false }
            return hypot(location.x - center.x, location.y - center.y) <= radius
        }

        private func selectJoint(_ joint: BodyJointName) {
            selectedJoint = joint
            parent.draggedJoint = joint // outward-facing binding — see its own doc comment
            rebuildSkeleton() // shows the highlight immediately, before any drag happens
        }

        private func beginJointDrag(joint: BodyJointName) {
            guard let startPosition = currentPositions[joint] else { return }
            isDraggingSelectedJoint = true
            dragPlaneAnchor = startPosition
        }

        /// Gets a screen-space ray from `ARView` and the camera's forward vector, then hands off to
        /// `JointDragProjector` (Core/PoseReconstruction) for the actual unprojection math — see
        /// that type's doc comment for the technique. UNVERIFIED ON DEVICE: `ARView.ray(through:)`
        /// is a real, documented RealityKit API (screen point -> world-space ray), also usable in
        /// non-AR camera mode.
        private func updateJointDrag(joint: BodyJointName, screenLocation: CGPoint) {
            guard let arView, let cameraEntity, let planePoint = dragPlaneAnchor,
                  let ray = arView.ray(through: screenLocation)
            else { return }

            let cameraForward = cameraEntity.orientation(relativeTo: nil).act(SIMD3<Float>(0, 0, -1))
            guard let targetWorldPosition = JointDragProjector.project(
                rayOrigin: ray.origin,
                rayDirection: ray.direction,
                planePoint: planePoint,
                planeNormal: cameraForward
            ) else { return }

            currentPositions = SkeletonPoseEditor.dragJoint(joint, to: targetWorldPosition, current: currentPositions, original: originalPositions)
            rebuildSkeleton()
        }

        /// Ends the current selection session entirely (step 5/6) — commits `currentPositions`
        /// back to `parent.jointOverrides` ONLY if something actually changed (a plain tap-select-
        /// then-tap-outside with no drag in between shouldn't mark the pose as edited), then clears
        /// the highlight and unlocks the camera.
        private func finishEditingSelectedJoint() {
            guard selectedJoint != nil else { return }
            selectedJoint = nil
            isDraggingSelectedJoint = false
            dragPlaneAnchor = nil
            parent.draggedJoint = nil
            if currentPositions != originalPositions {
                parent.jointOverrides = currentPositions
                parent.hasEditedPose = true
                hasAppliedOverride = true
            }
            rebuildSkeleton() // clears the highlight
        }

        /// Reverts to the auto-detected pose — called from `updateUIView` when "Reset Pose" sets
        /// `parent.jointOverrides` back to nil.
        func resetToOriginal() {
            currentPositions = originalPositions
            selectedJoint = nil
            isDraggingSelectedJoint = false
            dragPlaneAnchor = nil
            parent.draggedJoint = nil
            hasAppliedOverride = false
            rebuildSkeleton()
        }

        /// Rebuilds the skeleton entity from `currentPositions` + whatever's being highlighted —
        /// the single path every drag start/change/end and external reset goes through, so there's
        /// one place that knows how to turn "current joint positions" into the rendered result.
        ///
        /// PERFORMANCE NOTE: this regenerates the whole skeleton (bones, joints, hand/foot
        /// presets — on the order of 50-70 small meshes) on every `.changed` gesture callback,
        /// rather than mutating the existing entities' transforms in place. Simpler and much less
        /// likely to have a subtle bug in a blind-coding workflow than incremental mutation, at
        /// the cost of some redundant mesh regeneration mid-drag. If dragging feels laggy on
        /// device, this is the first place to optimize (e.g. only regenerate the one pivot bone's
        /// orientation and translate the rest, matching how `SkeletonPoseEditor.dragJoint` already
        /// computes the update).
        func rebuildSkeleton() {
            // `parent.poseSample` may be nil here (a loaded session-review reconstruction, with no
            // fresh Vision detection) — `currentPositions` always has whatever's actually being
            // rendered regardless (seeded from `initialWorldPositions` in that case, see
            // `makeUIView`), and `skeletonEntity` only reads `sample` when `overridePositions` is
            // nil, which is never true here since `overridePositions: currentPositions` is always
            // passed below.
            guard let contentAnchor else { return }
            if let skeletonEntityRef {
                contentAnchor.removeChild(skeletonEntityRef)
            }
            let highlighted = selectedJoint.map { (joints: SkeletonPoseEditor.impactedJoints(for: $0), bones: SkeletonPoseEditor.impactedBones(for: $0)) }
            let newSkeleton = ReconstructionEntityBuilder.skeletonEntity(
                from: parent.poseSample,
                cameraTransform: parent.cameraTransform ?? matrix_identity_float4x4,
                depthContext: parent.depthContext,
                wallReference: parent.wallTextureReference,
                overridePositions: currentPositions,
                highlightedJoints: highlighted?.joints ?? [],
                highlightedBones: highlighted?.bones ?? [],
                hideMannequinBody: parent.isEditingPose
            )
            contentAnchor.addChild(newSkeleton)
            skeletonEntityRef = newSkeleton
        }

        /// Pinch to zoom — shrinks/grows the orbit radius. Clamped so you can't zoom through the
        /// content or pinch out to a speck. Locked out while a joint is selected — see
        /// `handleJointTouch`'s doc comment, step 2.
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard selectedJoint == nil, gesture.scale.isFinite, gesture.scale > 0 else { return }
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
            // Locked out while a joint is selected — see `handleJointTouch`'s doc comment, step 2.
            guard selectedJoint == nil, let cameraEntity else { return }
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

//
//  Skeleton3DSceneView.swift
//  SendSociety
//
//  Created by Christofer Theodore on 15/08/26.
//

import SwiftUI
import RealityKit
import ARKit
import simd

final class SceneCommitTrigger {
    var commit: (() -> Void)?
}
struct Skeleton3DSceneView: UIViewRepresentable {
    let wallAnchors: [ARMeshAnchor]
    let wallTextureReference: ARSessionManager.WallTextureReference?
    let appleVisionSkeleton: AppleVisionSkeleton?
    let cameraTransform: simd_float4x4?
    let depthContext: AppleVisionSkeletonExtractor.DepthGroundingContext?
    let isEditingPose: Bool
    @Binding var jointOverrides: [BodyJointName: SIMD3<Float>]?
    @Binding var draggedJoint: BodyJointName?
    @Binding var hasEditedPose: Bool
    let originalAppleVisionJoints: [BodyJointName: SIMD3<Float>]?
    let commitTrigger: SceneCommitTrigger
    

    func makeUIView(context: Context) -> ARView {
        // cameraMode: .nonAR — a plain 3D scene, not a live camera-passthrough AR view.
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        // Neutral light gray instead of pure black — reads as a lit room rather than a void.
        view.environment.background = .color(UIColor(white: 0.85, alpha: 1.0))
        context.coordinator.parent = self
        context.coordinator.arView = view

        let contentAnchor = AnchorEntity(world: .zero)
        contentAnchor.addChild(Video3DRealityKit.wallEntity(from: wallAnchors, textureReference: wallTextureReference))
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

        let skeletonPositions = originalAppleVisionJoints ?? (appleVisionSkeleton.map {
            Video3DRealityKit.generate3DJointPositions(from: $0, cameraTransform: cameraTransform ?? matrix_identity_float4x4, depthContext: depthContext, wallReference: wallTextureReference)
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
        
        
        commitTrigger.commit = { [weak coordinator = context.coordinator] in
            coordinator?.finishEditingSelection()
        }

        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.parent = self
        if jointOverrides == nil, context.coordinator.hasAppliedOverride {
            context.coordinator.resetToOriginal()
            return
        }
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
        depthContext: AppleVisionSkeletonExtractor.DepthGroundingContext?,
        wallAnchors: [ARMeshAnchor]
    ) -> (target: SIMD3<Float>, radius: Float, elevation: Float, azimuth: Float)? {
        let column = recordingCameraTransform.columns.3
        let position = SIMD3<Float>(column.x, column.y, column.z)
        let forward4 = recordingCameraTransform * SIMD4<Float>(0, 0, -1, 0)
        let forward = SIMD3<Float>(forward4.x, forward4.y, forward4.z)

        var target: SIMD3<Float>?
        if let depthContext, let distance = Video3DRealityKit.centerDepthMeters(from: depthContext) {
            target = position + forward * distance
        }
        if target == nil {
            target = Video3DRealityKit.surfacePoint(nearRayFrom: position, direction: forward, in: wallAnchors)
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
        var parent: Skeleton3DSceneView
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

        var originalPositions: [BodyJointName: SIMD3<Float>] = [:]
        var currentPositions: [BodyJointName: SIMD3<Float>] = [:]

        /// What's currently selected — a real joint, or the synthetic whole-body handle cube. Persists
        /// across separate touches once tapped (camera stays locked, highlight stays on) until the
        /// coach taps outside its radius — same rules for both kinds now, unified into one type.
        private enum SkeletonSelection: Equatable {
            case joint(BodyJointName)
            case wholeBodyHandle
        }
        private var selection: SkeletonSelection?
        private var isDraggingSelectedJoint = false
        private var isDraggingWholeBody = false
        private var dragPlaneAnchor: SIMD3<Float>?
        private var lastOrbitTouchLocation: CGPoint?
        private var lastBodyDragLocation: CGPoint?
        private let jointSelectionRadius: Float = 0.08
        private let wholeBodyHandleSelectionRadius: Float = 0.12
        private let wholeBodyHandleHeightOffset: Float = 0.4   // how far above the hip the cube floats — tune on device
        var hasAppliedOverride = false
        
        private enum HandleAxis: CaseIterable {
            case x, y, z
            var worldDirection: SIMD3<Float> {
                switch self {
                case .x: return SIMD3<Float>(1, 0, 0)
                case .y: return SIMD3<Float>(0, 1, 0)
                case .z: return SIMD3<Float>(0, 0, 1)
                }
            }
        }
        private var draggedAxis: HandleAxis?
        private var axisDragAnchor: (screenLocation: CGPoint, startPosition: SIMD3<Float>)?
        private var bodyDragStartPositions: [BodyJointName: SIMD3<Float>]?
        private let axisHandleLength: Float = 0.15        // how far the arrow tip sits from the selected point — tune on device
        private let axisHandleSelectionRadius: Float = 0.05

        init(parent: Skeleton3DSceneView) {
            self.parent = parent
        }
        private static func closestPointOnLine(lineOrigin: SIMD3<Float>, lineDirection: SIMD3<Float>, rayOrigin: SIMD3<Float>, rayDirection: SIMD3<Float>) -> SIMD3<Float>? {
            let d1 = simd_normalize(rayDirection)
            let d2 = simd_normalize(lineDirection)
            let w0 = rayOrigin - lineOrigin
            let a = simd_dot(d1, d1)
            let b = simd_dot(d1, d2)
            let c = simd_dot(d2, d2)
            let d = simd_dot(d1, w0)
            let e = simd_dot(d2, w0)
            let denom = a * c - b * b
            guard abs(denom) > 1e-5 else { return nil }   // ray nearly parallel to the axis — no stable answer, ignore this frame
            let t2 = (a * e - b * d) / denom
            return lineOrigin + d2 * t2
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
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

        @objc func handleJointTouch(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                switch selection {
                case .joint(let selected):
                    if let axis = axisHandleWithinRadius(at: location, around: currentPositions[selected]) {
                        beginAxisDrag(axis: axis, at: location, startPosition: currentPositions[selected]!)
                    } else if withinRadius(selected, at: location) {
                        beginJointDrag(joint: selected)
                    } else if let other = jointWithinRadius(at: location, excluding: selected) {
                        finishEditingSelection()
                        selectJoint(other)
                    } else if withinCubeRadius(at: location) {
                        finishEditingSelection()
                        selectWholeBodyHandle()
                    } else {
                        finishEditingSelection()
                    }
                case .wholeBodyHandle:
                    if let axis = axisHandleWithinRadius(at: location, around: cubeWorldPosition) {
                        beginAxisDrag(axis: axis, at: location, startPosition: cubeWorldPosition!)
                    } else if withinCubeRadius(at: location) {
                        isDraggingWholeBody = true
                        lastBodyDragLocation = location
                    } else if let joint = jointWithinRadius(at: location) {
                        finishEditingSelection()
                        selectJoint(joint)
                    } else {
                        finishEditingSelection()
                    }
                case .none:
                    if let joint = jointWithinRadius(at: location) {
                        selectJoint(joint)
                    } else if withinCubeRadius(at: location) {
                        selectWholeBodyHandle()
                    } else {
                        lastOrbitTouchLocation = location
                    }
                }
            case .changed:
                if draggedAxis != nil {
                    updateAxisDrag(screenLocation: location)
                } else if isDraggingSelectedJoint, case .joint(let selected) = selection {
                    updateJointDrag(joint: selected, screenLocation: location)
                } else if isDraggingWholeBody, let last = lastBodyDragLocation {
                    updateBodyDrag(from: last, to: location)
                    lastBodyDragLocation = location
                } else if selection == nil, let last = lastOrbitTouchLocation {
                    let dx = Float(location.x - last.x)
                    let dy = Float(location.y - last.y)
                    azimuth -= dx * 0.005
                    elevation = max(-1.4, min(1.4, elevation - dy * 0.005))
                    lastOrbitTouchLocation = location
                    updateCameraTransform()
                }
            case .ended, .cancelled, .failed:
                if draggedAxis != nil {
                    draggedAxis = nil
                    axisDragAnchor = nil
                    bodyDragStartPositions = nil
                } else if isDraggingSelectedJoint {
                    isDraggingSelectedJoint = false
                    dragPlaneAnchor = nil
                } else if isDraggingWholeBody {
                    isDraggingWholeBody = false
                    lastBodyDragLocation = nil
                }
                lastOrbitTouchLocation = nil
            default:
                break
            }
        }

        private func screenRadius(forWorldPosition worldPosition: SIMD3<Float>, selectionRadiusMeters: Float, in view: ARView) -> (center: CGPoint, radius: CGFloat)? {
            guard let cameraEntity, let centerScreen = view.project(worldPosition) else { return nil }
            let right = cameraEntity.orientation(relativeTo: nil).act(SIMD3<Float>(1, 0, 0))
            let edgeWorld = worldPosition + right * selectionRadiusMeters
            guard let edgeScreen = view.project(edgeWorld) else { return nil }
            let pixelRadius = hypot(edgeScreen.x - centerScreen.x, edgeScreen.y - centerScreen.y)
            return (centerScreen, max(24, pixelRadius))
        }

        private func screenRadius(for joint: BodyJointName, in view: ARView) -> (center: CGPoint, radius: CGFloat)? {
            guard let worldPosition = currentPositions[joint] else { return nil }
            return screenRadius(forWorldPosition: worldPosition, selectionRadiusMeters: jointSelectionRadius, in: view)
        }
        
        private func axisHandleWithinRadius(at location: CGPoint, around origin: SIMD3<Float>?) -> HandleAxis? {
            guard let arView, let origin else { return nil }
            var best: (axis: HandleAxis, distance: CGFloat)?
            for axis in HandleAxis.allCases {
                let handlePosition = origin + axis.worldDirection * axisHandleLength
                guard let (center, radius) = screenRadius(forWorldPosition: handlePosition, selectionRadiusMeters: axisHandleSelectionRadius, in: arView) else { continue }
                let distance = hypot(location.x - center.x, location.y - center.y)
                guard distance <= radius else { continue }
                if best == nil || distance < best!.distance { best = (axis, distance) }
            }
            return best?.axis
        }
        private func beginAxisDrag(axis: HandleAxis, at location: CGPoint, startPosition: SIMD3<Float>) {
            draggedAxis = axis
            axisDragAnchor = (location, startPosition)
            if selection == .wholeBodyHandle {
                bodyDragStartPositions = currentPositions
            }
        }

        private func updateAxisDrag(screenLocation: CGPoint) {
            guard let axis = draggedAxis, let anchor = axisDragAnchor, let arView,
                  let ray = arView.ray(through: screenLocation),
                  let targetOnAxis = Self.closestPointOnLine(lineOrigin: anchor.startPosition, lineDirection: axis.worldDirection, rayOrigin: ray.origin, rayDirection: ray.direction)
            else { return }

            switch selection {
            case .joint(let joint):
                currentPositions = SkeletonPoseEditor.dragJoint(joint, to: targetOnAxis, current: currentPositions, original: originalPositions)
            case .wholeBodyHandle:
                guard let startPositions = bodyDragStartPositions else { return }
                let delta = targetOnAxis - anchor.startPosition
                for (joint, startPos) in startPositions {
                    currentPositions[joint] = startPos + delta
                }
            case .none:
                break
            }
            rebuildSkeleton()
        }

        private var cubeWorldPosition: SIMD3<Float>? {
            guard let hip = currentPositions[.root] else { return nil }
            return SIMD3<Float>(hip.x, hip.y + wholeBodyHandleHeightOffset, hip.z)
        }

        private func withinCubeRadius(at location: CGPoint) -> Bool {
            guard let arView, let cubePosition = cubeWorldPosition,
                  let (center, radius) = screenRadius(forWorldPosition: cubePosition, selectionRadiusMeters: wholeBodyHandleSelectionRadius, in: arView)
            else { return false }
            return hypot(location.x - center.x, location.y - center.y) <= radius
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
            selection = .joint(joint)
            parent.draggedJoint = joint
            rebuildSkeleton()
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

        /// Reverts to the auto-detected pose — called from `updateUIView` when "Reset Pose" sets
        /// `parent.jointOverrides` back to nil.
        func resetToOriginal() {
            currentPositions = originalPositions
            selection = nil
            isDraggingSelectedJoint = false
            isDraggingWholeBody = false
            dragPlaneAnchor = nil
            lastBodyDragLocation = nil
            parent.draggedJoint = nil
            hasAppliedOverride = false
            rebuildSkeleton()
        }
        
        private func selectWholeBodyHandle() {
            selection = .wholeBodyHandle
            parent.draggedJoint = nil
            rebuildSkeleton()
        }

        private func updateBodyDrag(from previousLocation: CGPoint, to currentLocation: CGPoint) {
            guard let cameraEntity else { return }
            let orientation = cameraEntity.orientation(relativeTo: nil)
            let right = orientation.act(SIMD3<Float>(1, 0, 0))
            let up = orientation.act(SIMD3<Float>(0, 1, 0))
            let dragScale = radius * 0.0015
            let dx = Float(currentLocation.x - previousLocation.x)
            let dy = Float(currentLocation.y - previousLocation.y)
            let delta = right * dx * dragScale - up * dy * dragScale
            for joint in currentPositions.keys {
                currentPositions[joint, default: .zero] += delta
            }
            rebuildSkeleton()
        }

        func finishEditingSelection() {
            guard selection != nil else { return }
            selection = nil
            isDraggingSelectedJoint = false
            isDraggingWholeBody = false
            dragPlaneAnchor = nil
            lastBodyDragLocation = nil
            parent.draggedJoint = nil
            if currentPositions != originalPositions {
                parent.jointOverrides = currentPositions
                parent.hasEditedPose = true
                hasAppliedOverride = true
            }
            rebuildSkeleton()
        }

        func rebuildSkeleton() {
            guard let contentAnchor else { return }
            if let skeletonEntityRef {
                contentAnchor.removeChild(skeletonEntityRef)
            }
            let highlightedJoint: BodyJointName? = {
                if case .joint(let j) = selection { return j }
                return nil
            }()
            let highlighted = highlightedJoint.map { (joints: SkeletonPoseEditor.impactedJoints(for: $0), bones: SkeletonPoseEditor.impactedBones(for: $0)) }
            let newSkeleton = Video3DRealityKit.skeletonEntity(
                from: parent.appleVisionSkeleton,
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

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard selection == nil, gesture.scale.isFinite, gesture.scale > 0 else { return }
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

            if selection == .wholeBodyHandle {
                let forward = cameraEntity.orientation(relativeTo: nil).act(SIMD3<Float>(0, 0, -1))
                let depthScale = radius * 0.0015
                let delta = forward * -Float(translation.y) * depthScale
                for joint in currentPositions.keys {
                    currentPositions[joint, default: .zero] += delta
                }
                rebuildSkeleton()
                return
            }

            guard selection == nil else { return }
            let orientation = cameraEntity.orientation(relativeTo: nil)
            let right = orientation.act(SIMD3<Float>(1, 0, 0))
            let up = orientation.act(SIMD3<Float>(0, 1, 0))
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

import simd

/// Lets a coach manually nudge a joint in the Step 4 reconstructed skeleton (to correct a spot
/// where auto-detection got it slightly wrong — occlusion against the wall, a missed frame, etc.)
/// while keeping the result anatomically plausible. Pure math, no RealityKit dependency, so it
/// stays a small, independently testable unit — `ReconstructionEntityBuilder` and
/// `ReconstructionView`'s drag-gesture code are the only callers.
///
/// RESEARCH NOTE — human joint range of motion (ROM), the basis for the constraints below.
/// These are standard, widely-cited clinical/kinesiology figures (the kind found in orthopedic
/// reference tables), not something specific to this app:
///
///   Joint      Motion                          Typical ROM
///   Shoulder   Flexion (arm forward/up)        0–180°
///              Extension (arm back)            0–60°
///              Abduction (arm out to the side)  0–180°
///              Internal/external rotation      ~90° each way
///   Elbow      Flexion                         0–145–150° (0° = straight)
///              Hyperextension                  ~0–10° only — effectively none
///   Hip        Flexion                         0–120° (more with the knee bent)
///              Extension                       0–20–30°
///              Abduction                       0–45°
///              Internal/external rotation      ~30–40° each
///   Knee       Flexion                         0–140°
///              Hyperextension                  ~0–10° only — effectively none
///   Ankle      Dorsiflexion / Plantarflexion   ~20° / ~50°
///   Neck/spine Flexion/extension/rotation      roughly 30–80° per segment, highly variable
///
/// The takeaway relevant here: the shoulder and hip are ball-and-socket joints with LARGE but
/// still bounded range (nowhere near 360° — e.g. you cannot point an upper arm straight backward
/// through the torso), while the elbow and knee are hinge joints with essentially ONE degree of
/// freedom (how bent they are) and almost no hyperextension past straight.
///
/// THE SIMPLIFICATION: this app's skeleton stores only 17 joint POSITIONS (see `BodyJointName`),
/// not per-joint rotations/twist — there's no "shoulder internal rotation" value to constrain
/// directly. So rather than modeling every anatomical axis, each bone gets ONE of two simplified
/// constraint types, which is the same practical simplification character-rigging and ragdoll
/// physics engines use (commonly called a "cone" or "cone-twist" limit) when they don't need
/// full joint-axis fidelity either:
///   - Ball-and-socket bones (shoulder→elbow, hip→knee, plus the mostly-rigid shoulder-girdle/
///     pelvis/neck/spine bones): constrained to a CONE around that bone's ORIGINAL (auto-detected)
///     direction — i.e. "you can drag this within roughly its natural range of the pose Vision
///     already found," not an absolute world-space cone, since the climber could be facing any
///     direction relative to the wall.
///   - Hinge bones (elbow→wrist limited by the elbow, knee→ankle limited by the knee): constrained
///     by the INTERIOR ANGLE at the hinge joint (180° = fully straight, smaller = more bent),
///     capped at a minimum bend angle and — because an angle-between-two-vectors calculation
///     mathematically tops out at 180° — hyperextension past fully straight falls out for free,
///     matching the "effectively none" ROM figures above without needing extra logic.
///
/// Every bone additionally preserves its ORIGINAL measured length exactly — real bones don't
/// stretch — and dragging any joint rigidly carries its whole downstream subtree along (an elbow
/// drag moves the forearm+hand with it; a wrist drag only moves the wrist).
enum SkeletonPoseEditor {

    /// Ball-and-socket cone half-angle (degrees) — how far a bone may swing away from its
    /// original detected direction. Starting points derived from the ROM table above, not tuned
    /// against real recaptures; the shoulder/hip values are intentionally generous (matching
    /// their genuinely large real ROM) while the girdle/spine values are tight (those barely move
    /// independently in reality).
    private static func coneHalfAngleDegrees(for joint: BodyJointName) -> Float {
        switch joint {
        case .leftElbow, .rightElbow: return 100 // shoulder ROM
        case .leftKnee, .rightKnee: return 80 // hip ROM
        case .leftShoulder, .rightShoulder: return 20 // shoulder girdle, fairly rigid
        case .leftHip, .rightHip: return 15 // pelvis, fairly rigid
        case .centerHead: return 35 // neck
        case .topHead: return 25 // head tilt
        case .spine: return 25 // torso lean
        case .centerShoulder: return 20 // upper torso relative to spine
        default: return 45 // generic fallback — shouldn't be hit given the joints above
        }
    }

    /// Hinge joints — the CHILD joint's drag is constrained by the interior angle formed at its
    /// PARENT (the actual hinge: elbow for the wrist, knee for the ankle), not by a cone around
    /// its own direction. Value is the minimum allowed interior angle (deepest allowed bend);
    /// the maximum is implicitly 180° (straight) — see the type doc comment for why.
    private static func hingeMinAngleDegrees(for joint: BodyJointName) -> Float? {
        switch joint {
        case .leftWrist, .rightWrist: return 25 // elbow flexion limit
        case .leftAnkle, .rightAnkle: return 25 // knee flexion limit
        default: return nil
        }
    }

    /// Parent lookup derived from `skeletonBones` (each bone's `from` is its `to`'s parent) —
    /// single source of truth for the skeleton's hierarchy, shared with rendering.
    private static func parent(of joint: BodyJointName) -> BodyJointName? {
        skeletonBones.first(where: { $0.to == joint })?.from
    }

    /// Every joint downstream of `joint` in the hierarchy (not including `joint` itself) — the
    /// set that rigidly translates along with it when it's dragged. `.root` has no parent bone,
    /// so this naturally returns every other joint for it (moving the root moves the whole body).
    static func descendants(of joint: BodyJointName) -> Set<BodyJointName> {
        var result: Set<BodyJointName> = []
        var frontier = [joint]
        while let current = frontier.popLast() {
            for bone in skeletonBones where bone.from == current {
                if result.insert(bone.to).inserted {
                    frontier.append(bone.to)
                }
            }
        }
        return result
    }

    /// `{joint} ∪ descendants(joint)` — every joint that will move if `joint` is dragged. Used
    /// both to actually move them (see `dragJoint`) and to highlight them before/during a drag so
    /// the coach can see what's about to be affected.
    static func impactedJoints(for joint: BodyJointName) -> Set<BodyJointName> {
        descendants(of: joint).union([joint])
    }

    /// Every bone entirely contained in `impactedJoints(for: joint)` — i.e. the pivot bone
    /// (parent → joint, whose DIRECTION is about to change) plus every bone further down the
    /// subtree (which only translates, keeping its own shape).
    static func impactedBones(for joint: BodyJointName) -> Set<SkeletonBone> {
        let impacted = impactedJoints(for: joint)
        return Set(skeletonBones.filter { impacted.contains($0.to) })
    }

    /// Computes the full updated joint-position dictionary after dragging `joint` toward
    /// `desiredWorldPosition`, applying bone-length preservation + the ROM constraint above, and
    /// rigidly translating `joint`'s descendant subtree by the resulting delta.
    ///
    /// - `current`: the skeleton's positions right now (reflects any earlier drags this session).
    /// - `original`: the very first auto-detected positions for this frame, BEFORE any manual
    ///   edits — used only as the reference direction for cone constraints (see the type doc
    ///   comment for why: constraints are relative to the pose Vision already found, not an
    ///   absolute world axis).
    static func dragJoint(
        _ joint: BodyJointName,
        to desiredWorldPosition: SIMD3<Float>,
        current: [BodyJointName: SIMD3<Float>],
        original: [BodyJointName: SIMD3<Float>]
    ) -> [BodyJointName: SIMD3<Float>] {
        guard let oldPosition = current[joint] else { return current }

        if joint == .root {
            let delta = desiredWorldPosition - oldPosition
            var updated = current
            for (j, position) in current { updated[j] = position + delta }
            return updated
        }

        guard let parentJoint = parent(of: joint), let parentPosition = current[parentJoint] else { return current }

        let length: Float
        if let originalChild = original[joint], let originalParent = original[parentJoint] {
            length = simd_distance(originalChild, originalParent)
        } else {
            length = simd_distance(oldPosition, parentPosition)
        }
        guard length > 0.001 else { return current }

        let rawDirection = desiredWorldPosition - parentPosition
        guard simd_length(rawDirection) > 0.0001 else { return current }
        let desiredDirection = normalize(rawDirection)

        let constrainedDirection: SIMD3<Float>
        if let minAngle = hingeMinAngleDegrees(for: joint),
           let grandparentJoint = parent(of: parentJoint),
           let grandparentPosition = current[grandparentJoint] {
            let reference = normalize(grandparentPosition - parentPosition)
            constrainedDirection = clampHinge(desiredDirection: desiredDirection, reference: reference, minAngleDegrees: minAngle)
        } else {
            let referenceDirection: SIMD3<Float>
            if let originalChild = original[joint], let originalParent = original[parentJoint] {
                let originalDirection = originalChild - originalParent
                referenceDirection = simd_length(originalDirection) > 0.0001 ? normalize(originalDirection) : desiredDirection
            } else {
                referenceDirection = desiredDirection
            }
            constrainedDirection = clampCone(desiredDirection: desiredDirection, referenceDirection: referenceDirection, maxAngleDegrees: coneHalfAngleDegrees(for: joint))
        }

        let newPosition = parentPosition + constrainedDirection * length
        var updated = current
        updated[joint] = newPosition

        let delta = newPosition - oldPosition
        for descendant in descendants(of: joint) {
            if let position = current[descendant] {
                updated[descendant] = position + delta
            }
        }
        return updated
    }

    /// Clamps `desiredDirection` to within `maxAngleDegrees` of `referenceDirection`, rotating it
    /// to the nearest point on the cone boundary if it's outside — otherwise returns it unchanged.
    private static func clampCone(desiredDirection: SIMD3<Float>, referenceDirection: SIMD3<Float>, maxAngleDegrees: Float) -> SIMD3<Float> {
        let maxAngle = maxAngleDegrees * .pi / 180
        let dot = min(max(simd_dot(desiredDirection, referenceDirection), -1), 1)
        let angle = acos(dot)
        guard angle > maxAngle else { return desiredDirection }
        let axis = simd_cross(referenceDirection, desiredDirection)
        guard simd_length(axis) > 0.0001 else { return referenceDirection } // desired is ~opposite reference — no unique swing axis
        let rotation = simd_quatf(angle: maxAngle, axis: normalize(axis))
        return rotation.act(referenceDirection)
    }

    /// Clamps `desiredDirection` so the interior angle it forms with `reference` (both measured
    /// from the shared pivot/hinge joint) is no smaller than `minAngleDegrees` — i.e. the hinge
    /// can't bend deeper than that. Angles above the minimum (including up to 180°, fully
    /// straight) pass through unchanged; nothing can exceed 180° since that's the natural ceiling
    /// of an angle between two vectors, which is what gives the "no hyperextension" behavior for
    /// free (see the type doc comment).
    private static func clampHinge(desiredDirection: SIMD3<Float>, reference: SIMD3<Float>, minAngleDegrees: Float) -> SIMD3<Float> {
        let minAngle = minAngleDegrees * .pi / 180
        let dot = min(max(simd_dot(reference, desiredDirection), -1), 1)
        let theta = acos(dot)
        guard theta < minAngle else { return desiredDirection }
        let axis = simd_cross(reference, desiredDirection)
        guard simd_length(axis) > 0.0001 else { return desiredDirection } // degenerate — fully folded onto the reference axis
        let rotation = simd_quatf(angle: minAngle, axis: normalize(axis))
        return rotation.act(reference)
    }
}

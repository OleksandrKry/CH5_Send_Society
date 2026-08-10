import simd

/// Small library of SCHEMATIC preset poses for each `HandGripType`/`FootPlacementType` — pure
/// data (joint offsets, box dimensions), no RealityKit dependency, so it stays a plain, testable
/// unit. `ReconstructionEntityBuilder` turns these into actual entities.
///
/// These are deliberately stylized, diagrammatic shapes built from simple offsets — the same
/// spirit as the mannequin body's fixed-radius capsules, NOT anatomically measured or sourced
/// from any real 3D asset. There's no 3D modeling tool or asset marketplace available in this
/// build environment, so "model or source a small set of hand/foot poses" (the original feature
/// ask) becomes "author simple procedural shapes" here — a deliberate, agreed-on trade-off: a
/// clearly-labeled schematic icon for "this is a half-crimp" is more honest and more useful than
/// an attempt at a photorealistic hand that this environment can't actually produce.
enum PresetPoseLibrary {

    // MARK: - Hands

    /// Canonical LOCAL-SPACE hand joint layout for a grip type, wrist at the origin.
    /// Convention: the forearm arrives from -Y and continues past the wrist toward +Y (i.e. the
    /// hand extends toward +Y); local +X is the "palm faces this way" reference axis used for the
    /// coarse wall-facing twist in `ReconstructionEntityBuilder.presetOrientation`. Built by hand
    /// from common climbing-technique descriptions of each grip, not measured from real climbers.
    static func handJointLayout(for grip: HandGripType) -> [HandJointName: SIMD3<Float>] {
        switch grip {
        case .jug:
            return makeHandLayout(fingerCurl: 0.35, spread: 1.0, thumbTipLocal: SIMD3<Float>(-0.05, 0.03, 0.03))
        case .openHand:
            return makeHandLayout(fingerCurl: 0.08, spread: 1.15, thumbTipLocal: SIMD3<Float>(-0.06, 0.02, 0.02))
        case .halfCrimp:
            return makeHandLayout(fingerCurl: 0.55, spread: 0.85, thumbTipLocal: SIMD3<Float>(-0.05, 0.02, 0.03))
        case .fullCrimp:
            return makeHandLayout(fingerCurl: 0.75, spread: 0.8, thumbTipLocal: SIMD3<Float>(-0.02, 0.05, -0.005), thumbBendsOverIndex: true)
        case .pinch:
            return makeHandLayout(fingerCurl: 0.4, spread: 0.55, thumbTipLocal: SIMD3<Float>(0.0, 0.04, -0.06))
        case .pocket:
            return makeHandLayout(fingerCurl: 0.7, spread: 0.35, thumbTipLocal: SIMD3<Float>(-0.03, 0.015, 0.02))
        case .sloper:
            return makeHandLayout(fingerCurl: 0.12, spread: 1.3, thumbTipLocal: SIMD3<Float>(-0.07, 0.015, 0.015))
        case .undercling:
            // Same finger geometry as a moderate-curl grip — the distinguishing cue for
            // undercling is the overall attachment rotation (palm facing away from the wall),
            // applied by the caller, not the local finger shape itself.
            return makeHandLayout(fingerCurl: 0.4, spread: 1.0, thumbTipLocal: SIMD3<Float>(-0.05, 0.03, 0.03))
        case .gaston:
            return makeHandLayout(fingerCurl: 0.45, spread: 0.9, thumbTipLocal: SIMD3<Float>(-0.05, 0.025, 0.025))
        }
    }

    /// Procedurally builds a schematic hand: 4 four-segment fingers spaced along local X, each
    /// bent by `fingerCurl` (0 = straight, 1 = folded back toward the palm), plus an explicitly
    /// positioned thumb. `spread` scales how far apart the four fingers sit.
    private static func makeHandLayout(
        fingerCurl: Float,
        spread: Float,
        thumbTipLocal: SIMD3<Float>,
        thumbBendsOverIndex: Bool = false
    ) -> [HandJointName: SIMD3<Float>] {
        var joints: [HandJointName: SIMD3<Float>] = [.wrist: .zero]
        let fingers: [(mcp: HandJointName, pip: HandJointName, dip: HandJointName, tip: HandJointName, xOffset: Float, length: Float)] = [
            (.indexMCP, .indexPIP, .indexDIP, .indexTip, -0.03 * spread, 0.09),
            (.middleMCP, .middlePIP, .middleDIP, .middleTip, -0.01 * spread, 0.10),
            (.ringMCP, .ringPIP, .ringDIP, .ringTip, 0.01 * spread, 0.09),
            (.littleMCP, .littlePIP, .littleDIP, .littleTip, 0.03 * spread, 0.07),
        ]
        for finger in fingers {
            let mcp = SIMD3<Float>(finger.xOffset, 0.02, 0)
            joints[finger.mcp] = mcp
            let segmentLength = finger.length / 3
            let bendAngle = fingerCurl * (.pi * 0.62) // up to ~112° total fold across 3 segments
            var position = mcp
            let chain: [HandJointName] = [finger.pip, finger.dip, finger.tip]
            for (index, jointName) in chain.enumerated() {
                // Bend increases toward the fingertip end so the curl reads as a knuckle fold,
                // not a uniform arc.
                let segmentBend = bendAngle * Float(index + 1) / 3
                let direction = normalize(SIMD3<Float>(0, cos(segmentBend), -sin(segmentBend)))
                position += direction * segmentLength
                joints[jointName] = position
            }
        }
        joints[.thumbCMC] = SIMD3<Float>(-0.045 * spread, -0.005, 0.01)
        joints[.thumbMP] = SIMD3<Float>(-0.045 * spread, 0.01, 0.015)
        joints[.thumbIP] = thumbBendsOverIndex
            ? (joints[.indexPIP] ?? SIMD3<Float>(-0.02, 0.03, -0.01))
            : SIMD3<Float>(-0.03 * spread, 0.025, 0.02)
        joints[.thumbTip] = thumbTipLocal
        return joints
    }

    // MARK: - Feet

    /// A schematic climbing-shoe box + local rotation/offset for a foot placement type, in LOCAL
    /// space: ankle at the origin, the knee sits in the local -Y direction (local +Y continues
    /// the shin's own downward direction past the ankle — this only matters for establishing the
    /// rotation frame; the shoe itself sits offset mostly along local Z, roughly perpendicular to
    /// the shin, the way a foot actually angles off the ankle).
    struct FootPresetShape {
        let boxSize: SIMD3<Float>
        let localOffset: SIMD3<Float>
        let localRotation: simd_quatf
    }

    static func footShape(for placement: FootPlacementType) -> FootPresetShape {
        let shoeWidth: Float = 0.09
        let shoeLength: Float = 0.24
        let shoeThickness: Float = 0.035
        switch placement {
        case .smear:
            // Flat against the surface — full sole contact, centered just past the ankle.
            return FootPresetShape(
                boxSize: SIMD3<Float>(shoeWidth, shoeThickness, shoeLength),
                localOffset: SIMD3<Float>(0, -0.03, 0.08),
                localRotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            )
        case .toe:
            // Tipped forward so only the front point makes contact — knee driven toward the
            // wall, heel lifted.
            return FootPresetShape(
                boxSize: SIMD3<Float>(shoeWidth * 0.8, shoeThickness, shoeLength),
                localOffset: SIMD3<Float>(0, -0.02, 0.1),
                localRotation: simd_quatf(angle: -0.9, axis: SIMD3<Float>(1, 0, 0))
            )
        case .heelHook:
            // Tipped the opposite way so the BACK of the shoe makes contact — paired with
            // `GripClassifier.classifyFoot` already using the raised-ankle skeleton signature to
            // select this case; this just orients the shoe shape to match visually.
            return FootPresetShape(
                boxSize: SIMD3<Float>(shoeWidth * 0.8, shoeThickness, shoeLength),
                localOffset: SIMD3<Float>(0, -0.02, -0.05),
                localRotation: simd_quatf(angle: 1.4, axis: SIMD3<Float>(1, 0, 0))
            )
        case .insideEdge:
            // Rolled onto the big-toe-side edge — one long edge of the sole is the lowest point
            // instead of the flat face.
            return FootPresetShape(
                boxSize: SIMD3<Float>(shoeWidth, shoeThickness, shoeLength),
                localOffset: SIMD3<Float>(0.02, -0.025, 0.08),
                localRotation: simd_quatf(angle: 0.6, axis: SIMD3<Float>(0, 0, 1))
            )
        case .outsideEdge:
            return FootPresetShape(
                boxSize: SIMD3<Float>(shoeWidth, shoeThickness, shoeLength),
                localOffset: SIMD3<Float>(-0.02, -0.025, 0.08),
                localRotation: simd_quatf(angle: -0.6, axis: SIMD3<Float>(0, 0, 1))
            )
        }
    }
}

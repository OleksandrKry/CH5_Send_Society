import simd

/// Classifies hand/foot contact into a small FIXED vocabulary (`HandGripType`/`FootPlacementType`)
/// instead of attempting precise raw geometry reconstruction, for two compounding reasons:
///
/// 1. LiDAR's real-world accuracy is roughly 1-3cm — close to the actual size of a finger or a
///    shoe's contact edge, i.e. close to the sensor's own noise floor.
/// 2. A hand gripping a hold, or a foot wedged on an edge, is close to worst-case occlusion for
///    Vision's 2D hand detector (no 3D hand API exists at all) — fingers overlap each other and
///    the hold; the shoe has no joints in Vision's output whatsoever, only the ankle.
///
/// So this replaces "reconstruct precise geometry" with "categorize which known type this looks
/// like" — a categorization problem instead of a measurement problem, which is far more tractable
/// under the same occlusion conditions.
///
/// IMPORTANT — WHAT THIS IS NOT: this is a hand-written heuristic (curl angles, spread ratios,
/// thumb-opposition distances, coarse hand/wall orientation), not a trained image classifier. A
/// real trained classifier needs labeled real climbing photos (ideally 50-100+ per category) to
/// learn from; none exist for this project, and none can be collected in this environment. Every
/// threshold below is a starting point derived from general climbing-technique knowledge about
/// how these grips/placements differ geometrically — NOT tuned against real gym footage. Expect
/// (and budget time for) adjusting these constants once this runs against real photos/video —
/// this is explicitly the part most likely to need real-world tuning, the same way the earlier
/// grip-type heuristics needed tuning in the web-based hand-tracking prototype.
enum GripClassifier {

    /// Below this many detected+grounded hand joints (out of 21), there isn't enough geometric
    /// signal to compute meaningful curl/spread features at all — `classifyHand` returns nil
    /// rather than guessing from noise. This is exactly the "heavy occlusion should still fail
    /// visibly" requirement: a fully-gripped, mostly-hidden hand often has 0-3 joints detected,
    /// well under this floor.
    static let minJointsForHandClassification = 6

    /// A classification below this confidence is shown to the coach as "uncertain," never as a
    /// named grip/placement — see `ReconstructionEntityBuilder.handAttachmentEntity`/
    /// `footAttachmentEntity`. Starting point only; THE primary value to tune once this is tested
    /// against real climbing footage.
    static let confidenceThreshold: Float = 0.45

    // MARK: - Hand grip classification

    /// Classifies a grip type from a hand's WORLD-SPACE joint positions (caller converts from the
    /// camera-space `HandPoseSample` — see `BodyPose3DExtractor.worldPosition`). `wallNormal`
    /// (world space, pointing away from the wall surface, toward the climber) is optional —
    /// without it, the orientation-distinctive types (sloper/undercling/gaston) can't be told
    /// apart from curl/spread alone, so classification falls through to the curl-based types,
    /// which shows up as those three specific grips being effectively unreachable rather than as
    /// a crash or a silent wrong answer.
    ///
    /// Returns nil when there are too few joints to say anything at all (see
    /// `minJointsForHandClassification`) — callers treat nil identically to a low-confidence
    /// result (show "uncertain"), so there's no separate code path to keep in sync.
    static func classifyHand(
        joints: [HandJointName: SIMD3<Float>],
        wristWorld: SIMD3<Float>,
        forearmDirection: SIMD3<Float>?,
        wallNormal: SIMD3<Float>?
    ) -> GripClassification? {
        guard joints.count >= minJointsForHandClassification else { return nil }

        func distance(_ a: HandJointName, _ b: HandJointName) -> Float? {
            guard let pa = joints[a], let pb = joints[b] else { return nil }
            return simd_distance(pa, pb)
        }

        // Curl = how much a finger's chain deviates from a straight line, normalized to [0, 1] —
        // 0 is fully straight, 1 is folded all the way back onto itself.
        func curl(_ mcp: HandJointName, _ pip: HandJointName, _ dip: HandJointName, _ tip: HandJointName) -> Float? {
            guard let straight = distance(mcp, tip),
                  let s1 = distance(mcp, pip), let s2 = distance(pip, dip), let s3 = distance(dip, tip)
            else { return nil }
            let pathLength = s1 + s2 + s3
            guard pathLength > 0.001 else { return nil }
            return min(max(1 - straight / pathLength, 0), 1)
        }

        // ~average adult palm length — fallback only, used purely to normalize other distances
        // into a hand-size-independent ratio when the wrist-to-knuckle measurement isn't itself
        // available.
        let handSize = distance(.wrist, .middleMCP) ?? 0.09

        let curls = [
            curl(.indexMCP, .indexPIP, .indexDIP, .indexTip),
            curl(.middleMCP, .middlePIP, .middleDIP, .middleTip),
            curl(.ringMCP, .ringPIP, .ringDIP, .ringTip),
            curl(.littleMCP, .littlePIP, .littleDIP, .littleTip),
        ].compactMap { $0 }
        let avgCurl = curls.isEmpty ? nil : curls.reduce(0, +) / Float(curls.count)

        let fingertips: [HandJointName] = [.indexTip, .middleTip, .ringTip, .littleTip]
        let availableTips = fingertips.compactMap { joints[$0] }
        var spreadRatio: Float?
        if availableTips.count >= 2 {
            var maxSpread: Float = 0
            for i in 0..<availableTips.count {
                for j in (i + 1)..<availableTips.count {
                    maxSpread = max(maxSpread, simd_distance(availableTips[i], availableTips[j]))
                }
            }
            spreadRatio = maxSpread / handSize
        }

        let thumbToIndexRatio = distance(.thumbTip, .indexTip).map { $0 / handSize }
        let thumbWrapRatio = (distance(.thumbTip, .indexPIP) ?? distance(.thumbTip, .indexDIP)).map { $0 / handSize }
        let activeFingertipCount = fingertips.filter { joints[$0] != nil }.count + (joints[.thumbTip] != nil ? 1 : 0)

        // Available-signal fraction drives the baseline confidence — more joints means every
        // feature above is built from more real data, not an assumption filling a gap. This is a
        // proxy for "how much geometry we actually had," not a calibrated probability.
        let signalFraction = Float(joints.count) / 21

        // Orientation-distinctive types first — curl/spread alone can't tell a sloper from a jug
        // (both can be low-curl/wide-spread); what actually distinguishes them is which way the
        // palm faces relative to the wall. Needs both a palm-normal estimate (from 3 hand joints)
        // and a wall normal — falls through to the curl-based types below when either is missing.
        if let wallNormal,
           let wrist = joints[.wrist], let indexMCP = joints[.indexMCP], let littleMCP = joints[.littleMCP] {
            let palmNormal = normalize(simd_cross(indexMCP - wrist, littleMCP - wrist))
            let facing = simd_dot(palmNormal, normalize(wallNormal))
            let curlForOrientation = avgCurl ?? 0.3
            let wideSpread = (spreadRatio ?? 0.8) > 1.0

            if facing < -0.45, curlForOrientation < 0.2, wideSpread {
                // Palm pressed toward the wall, barely curled, fingers splayed — a flat push.
                return GripClassification(type: .sloper, confidence: min(0.35 + signalFraction * 0.5, 0.9))
            }
            if abs(facing) < 0.35, curlForOrientation < 0.55 {
                // Palm roughly edge-on to the wall — rotated to the side rather than pulling
                // straight down or pushing flat.
                return GripClassification(type: .gaston, confidence: min(0.25 + signalFraction * 0.45, 0.8))
            }
            if facing > 0.45, curlForOrientation < 0.55 {
                // Palm facing away from the wall — pulling from underneath a hold.
                return GripClassification(type: .undercling, confidence: min(0.25 + signalFraction * 0.45, 0.8))
            }
        }

        // Curl/spread/thumb-based types — the primary path when orientation signal isn't
        // available, or didn't clearly match one of the three cases above.
        let curlValue = avgCurl ?? 0.3
        let spreadValue = spreadRatio ?? 0.8

        if let thumbWrapRatio, thumbWrapRatio < 0.35, curlValue > 0.5 {
            return GripClassification(type: .fullCrimp, confidence: min(0.4 + signalFraction * 0.5, 0.92))
        }
        if curlValue > 0.4 {
            return GripClassification(type: .halfCrimp, confidence: min(0.35 + signalFraction * 0.5, 0.85))
        }
        if let thumbToIndexRatio, thumbToIndexRatio < 0.35, spreadValue < 0.6 {
            return GripClassification(type: .pinch, confidence: min(0.3 + signalFraction * 0.5, 0.85))
        }
        if activeFingertipCount <= 2, curlValue > 0.25 {
            return GripClassification(type: .pocket, confidence: min(0.25 + signalFraction * 0.45, 0.75))
        }
        if curlValue < 0.18, spreadValue > 1.0 {
            return GripClassification(type: .openHand, confidence: min(0.3 + signalFraction * 0.5, 0.85))
        }
        return GripClassification(type: .jug, confidence: min(0.25 + signalFraction * 0.45, 0.75))
    }

    // MARK: - Foot placement classification

    /// Classifies a foot placement type from skeleton geometry ALONE — ankle/knee/hip world
    /// positions and the coarse wall plane. Unlike hands, there's no Vision joint data for the
    /// foot itself at all (no toe/heel points exist in `VNDetectHumanBodyPose3DRequest`'s output,
    /// only the ankle), so this has meaningfully less to work with than the hand classifier above
    /// — expect foot confidence to run lower across the board and to need the most real-world
    /// tuning of the two classifiers.
    ///
    /// Note this is the OPPOSITE of what a pure image-crop classifier would see — a rigid
    /// climbing shoe is genuinely easier to recognize visually than a deformable hand. It's
    /// specifically this skeleton-only heuristic approach that flips which one is harder, since
    /// it has no shoe pixels to look at, only two joint positions and a plane.
    static func classifyFoot(
        ankleWorld: SIMD3<Float>,
        hipWorld: SIMD3<Float>?,
        shinDirection: SIMD3<Float>?,
        wallNormal: SIMD3<Float>?
    ) -> FootClassification? {
        // Heel hook: the most geometrically distinctive case — the foot raised to around hip
        // height or above, which never happens for a normal standing/stepping placement. Checked
        // first since it's detectable from hip/ankle alone, no shin direction needed.
        if let hipWorld {
            let heightAboveHip = ankleWorld.y - hipWorld.y
            if heightAboveHip > -0.15 {
                let confidence: Float = heightAboveHip > 0.05 ? 0.6 : 0.4
                return FootClassification(type: .heelHook, confidence: confidence)
            }
        }

        guard let shinDirection, simd_length(shinDirection) > 0.001, let wallNormal else {
            // Not enough geometry to say anything more specific than "some kind of normal
            // placement" — rather than guess among edge/toe/smear with zero signal, report a
            // low-confidence smear (the most common, least committal placement) so it still
            // reads as an honest low-confidence guess, not a crash or a missing value.
            return FootClassification(type: .smear, confidence: 0.2)
        }

        let shin = normalize(shinDirection)
        let normal = normalize(wallNormal)
        // How square-on the shin is to the wall — near 0 means the shin runs roughly parallel to
        // the wall face (knee driven in sideways/low, more edge-like); near 1 means the knee is
        // driven straight toward the wall (more toe-like). Genuinely weak signal — there's no
        // actual foot/toe rotation data available, only this one proxy — hence the capped
        // confidence values throughout this method.
        let shinIntoWall = abs(simd_dot(shin, normal))

        if shinIntoWall > 0.5 {
            return FootClassification(type: .toe, confidence: 0.4)
        }

        // Left/right lean of the shin (relative to world up, projected across the wall) as a
        // rough proxy for which edge of the shoe is likely down. Sign convention is a guess, not
        // verified against real footage — if inside/outside edge come out swapped on real
        // climbers, flip the two `lean` comparisons below.
        let worldUp = SIMD3<Float>(0, 1, 0)
        let alongWall = normalize(simd_cross(normal, worldUp))
        let lean = simd_dot(shin, alongWall)
        if lean > 0.2 {
            return FootClassification(type: .outsideEdge, confidence: 0.3)
        }
        if lean < -0.2 {
            return FootClassification(type: .insideEdge, confidence: 0.3)
        }
        return FootClassification(type: .smear, confidence: 0.35)
    }
}

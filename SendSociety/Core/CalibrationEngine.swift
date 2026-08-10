import Foundation
import simd

/// Captures several BodyPoseSample frames while the climber holds a T-pose, averages the
/// per-joint positions to reduce per-frame noise, and derives real-world segment lengths.
final class CalibrationEngine: ObservableObject {

    @Published private(set) var collectedFrameCount = 0
    @Published private(set) var result: CalibrationResult?
    @Published private(set) var isCollecting = false

    private var samples: [[BodyJointName: SIMD3<Float>]] = []
    let targetFrameCount: Int

    /// Joints that must all be present for a frame to count — a partial detection (climber
    /// stepped out of frame, occlusion, etc.) shouldn't corrupt the average.
    private static let requiredJoints: [BodyJointName] = [
        .root, .spine, .centerShoulder, .leftShoulder, .rightShoulder,
        .leftElbow, .rightElbow, .leftWrist, .rightWrist,
        .leftHip, .rightHip, .leftKnee, .rightKnee,
        .leftAnkle, .rightAnkle, .topHead,
    ]

    init(targetFrameCount: Int = 45) {
        self.targetFrameCount = targetFrameCount
    }

    func reset() {
        samples.removeAll()
        collectedFrameCount = 0
        result = nil
        isCollecting = true
    }

    /// Feed one frame's worth of joints. Returns true once enough frames have been collected and
    /// averaging has completed.
    @discardableResult
    func ingest(_ joints: [BodyJointName: SIMD3<Float>]) -> Bool {
        guard isCollecting else { return false }
        guard Self.requiredJoints.allSatisfy({ joints[$0] != nil }) else { return false }

        samples.append(joints)
        collectedFrameCount = samples.count
        DebugLog.calibration.info("Calibration frame \(self.collectedFrameCount, privacy: .public)/\(self.targetFrameCount, privacy: .public) captured")

        if samples.count >= targetFrameCount {
            finish()
            return true
        }
        return false
    }

    private func finish() {
        isCollecting = false
        var sums: [BodyJointName: SIMD3<Float>] = [:]
        var counts: [BodyJointName: Int] = [:]
        for frame in samples {
            for (joint, position) in frame {
                sums[joint, default: .zero] += position
                counts[joint, default: 0] += 1
            }
        }
        var averaged: [BodyJointName: SIMD3<Float>] = [:]
        for (joint, sum) in sums {
            averaged[joint] = sum / Float(counts[joint] ?? 1)
        }

        let segments = Self.deriveSegments(from: averaged)
        result = CalibrationResult(
            segments: segments,
            frameCount: samples.count,
            averagedJoints: averaged,
            capturedAt: Date()
        )

        let heightStr = String(format: "%.2f", segments.height)
        let spanStr = String(format: "%.2f", segments.armSpan)
        DebugLog.calibration.info("Calibration complete over \(self.samples.count, privacy: .public) frames — height: \(heightStr, privacy: .public)m, armSpan: \(spanStr, privacy: .public)m")
    }

    private static func deriveSegments(from j: [BodyJointName: SIMD3<Float>]) -> SegmentLengths {
        func dist(_ a: BodyJointName, _ b: BodyJointName) -> Float? {
            guard let pa = j[a], let pb = j[b] else { return nil }
            return simd_distance(pa, pb)
        }
        func avg(_ a: Float?, _ b: Float?) -> Float {
            switch (a, b) {
            case let (x?, y?): return (x + y) / 2
            case let (x?, nil): return x
            case let (nil, y?): return y
            default: return 0
            }
        }

        var segments = SegmentLengths()
        segments.upperArmLength = avg(dist(.leftShoulder, .leftElbow), dist(.rightShoulder, .rightElbow))
        segments.forearmLength = avg(dist(.leftElbow, .leftWrist), dist(.rightElbow, .rightWrist))
        segments.thighLength = avg(dist(.leftHip, .leftKnee), dist(.rightHip, .rightKnee))
        segments.shinLength = avg(dist(.leftKnee, .leftAnkle), dist(.rightKnee, .rightAnkle))
        segments.torsoLength = dist(.centerShoulder, .root) ?? 0
        // Rough placeholder — the 17-joint set has no dedicated hand/finger joints.
        segments.handSpan = segments.forearmLength * 0.45

        if let head = j[.topHead], let leftAnkle = j[.leftAnkle], let rightAnkle = j[.rightAnkle] {
            let ankle = leftAnkle.y < rightAnkle.y ? leftAnkle : rightAnkle
            segments.height = simd_distance(head, ankle)
        }
        if let lw = j[.leftWrist], let rw = j[.rightWrist] {
            segments.armSpan = simd_distance(lw, rw)
        }

        return segments
    }
}

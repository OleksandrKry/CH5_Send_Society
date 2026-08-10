import ARKit
import Combine
import simd
import UIKit

/// CAPTURE MODULE: everything in `Core/Capture/` is about getting real-world data IN — the live
/// ARSession, camera frames, depth, and the recorded video file. Nothing in this folder knows
/// about Vision body-pose detection, grip/foot classification, or RealityKit rendering (that's
/// `Core/Reconstruction/`) or how a session gets saved to disk (that's `Core/Persistence/`).
/// `ARSessionManager` is this module's main entry point — most other modules only ever need it
/// (and its `WallTextureReference`) or `VideoRecorder`/`RecordedFrameStore`, not the smaller
/// helper files.
///
/// Owns the single, continuously-running ARSession shared across Steps 1-3.
///
/// CRITICAL: per the build brief, the wall scan and the recording MUST share one ARSession
/// instance. Restarting the session between steps forces ARKit to relocalize, and the wall's
/// coordinate space can drift out of alignment with the body's coordinate space — this MVP has
/// no fallback for that. `startIfNeeded()` is guarded so the session can only ever be started
/// once per app launch.
final class ARSessionManager: NSObject, ObservableObject, ARSessionDelegate {

    /// A single color frame + the camera pose/intrinsics it was captured with, kept around so
    /// Step 4 can project real captured pixels onto the wall mesh instead of a flat placeholder
    /// color. Captured once, when the coach taps "Done Scanning" in Step 1 — see
    /// `captureWallTextureReference()`.
    struct WallTextureReference {
        let colorImage: CVPixelBuffer
        let cameraTransform: simd_float4x4
        let intrinsics: simd_float3x3
        let imageResolution: CGSize
        /// Raw LiDAR depth grid for this SAME frame, used to build a dense, per-pixel heightfield
        /// wall mesh (real bump relief) instead of ARKit's coarse, smoothed `ARMeshAnchor`
        /// triangulation — see `ReconstructionEntityBuilder.pointCloudWallEntity`. Optional
        /// because sceneDepth could theoretically be unavailable; nil falls back to the coarse
        /// mesh.
        let depthMap: CVPixelBuffer?
        let confidenceMap: CVPixelBuffer?
        /// Average confident LiDAR depth across this reference frame — a crude "how far away is
        /// the wall, roughly" number used to approximate the wall as a flat plane (see
        /// `ReconstructionEntityBuilder.wallPlane`), so Step 4 can sanity-check that the climber's
        /// skeleton isn't accidentally rendering behind the wall. nil if depth wasn't available.
        let averageDepth: Float?
    }

    let session = ARSession()

    @Published private(set) var trackingQuality: TrackingQuality = .normal
    @Published private(set) var meshAnchors: [ARMeshAnchor] = []
    @Published private(set) var latestFrame: ARFrame?
    @Published private(set) var isRunning = false
    @Published private(set) var wallTextureReference: WallTextureReference?

    /// A FROZEN copy of `meshAnchors` taken the moment Step 1 scanning is marked done (see
    /// `captureWallTextureReference()`). Step 4 renders THIS, not the live `meshAnchors`.
    ///
    /// Why this exists: the ARSession keeps running (and scene reconstruction keeps growing/
    /// updating mesh anchors) through Steps 2 and 3, per the brief's one-continuous-session
    /// requirement. ARKit's mesh reconstruction meshes whatever the LiDAR sees — including the
    /// climber's own body while they stand in front of the wall for calibration and the climb —
    /// and it's slow to prune stale geometry once a person moves. Left live, Step 4's "wall"
    /// picks up floor slivers, room clutter caught at the edge of frame, and leftover blob
    /// geometry shaped like wherever the climber's body sat during Steps 2-3 — which is almost
    /// certainly what shows up as unexplained mesh far from the actual wall, and as the
    /// skeleton appearing to be embedded IN the wall (it's actually sitting inside a residual
    /// body-shaped mesh chunk, textured like the wall, at the same spot).
    @Published private(set) var wallMeshSnapshot: [ARMeshAnchor] = []

    /// Low-level hook invoked synchronously on every frame update, used by Step 3 recording to
    /// feed frames into VideoRecorder. Deliberately not routed through @Published — ARFrame
    /// isn't Equatable, so a SwiftUI onChange-based approach would silently miss frames.
    var onFrameUpdate: ((ARFrame) -> Void)?

    private var didConfigure = false

    override init() {
        super.init()
        session.delegate = self
    }

    func startIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        if type(of: configuration).supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        configuration.environmentTexturing = .none
        // Plane detection was on but nothing in this app ever reads an `ARPlaneAnchor` — the wall
        // itself comes from `sceneReconstruction`'s mesh + raw depth, never from a detected plane.
        // It's pure extra per-frame work for output nobody consumes, competing for the same
        // real-time budget as ARKit's own tracking/SLAM — worth cutting given the reported
        // "poor slam" tracking degradation and crash during recording (a large, relatively
        // low-texture climbing wall is already a hard scene for visual tracking on its own; no
        // reason to also make ARKit hunt for planes in it).

        session.run(configuration)
        isRunning = true
        DebugLog.general.info("ARSession started — one continuous session shared across Steps 1-3")
    }

    /// Snapshots the current frame's color image + camera pose/intrinsics as the reference used
    /// to texture the wall mesh in Step 4. Call once, when wall scanning is marked done — a
    /// single representative frame (ideally a clear overview of the wall) is enough for this
    /// MVP; it will look correct where that frame had a clean view of the wall and increasingly
    /// wrong (stretched/wrong color) for surface areas that frame couldn't see well. True
    /// multi-frame texture blending is a bigger separate feature.
    func captureWallTextureReference() {
        // Freeze the wall's mesh geometry HERE too, not just the color reference — see
        // `wallMeshSnapshot`'s doc comment for why Step 4 must not keep reading the live,
        // still-growing `meshAnchors` after this point.
        wallMeshSnapshot = meshAnchors
        DebugLog.reconstruction.info("Froze wall mesh snapshot at \(self.meshAnchors.count, privacy: .public) anchors")

        guard let frame = latestFrame, let imageCopy = PixelBufferCopy.copy(frame.capturedImage) else {
            DebugLog.reconstruction.error("Could not capture a wall texture reference frame — Step 4 will fall back to a flat gray wall")
            return
        }
        // Parens required — see the identical gotcha already flagged in RecordedFrameStore.record.
        let depthCopy = (frame.sceneDepth?.depthMap).flatMap(PixelBufferCopy.copy)
        let confidenceCopy = (frame.sceneDepth?.confidenceMap).flatMap(PixelBufferCopy.copy)
        if depthCopy == nil {
            DebugLog.reconstruction.error("No scene depth for the wall reference frame — Step 4 wall will use the coarse ARMeshAnchor mesh instead of a bump-detailed surface")
        }
        wallTextureReference = WallTextureReference(
            colorImage: imageCopy,
            cameraTransform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageResolution: frame.camera.imageResolution,
            depthMap: depthCopy,
            confidenceMap: confidenceCopy,
            averageDepth: depthCopy.flatMap { Self.averageConfidentDepth(depthMap: $0, confidenceMap: confidenceCopy) }
        )
        DebugLog.reconstruction.info("Captured wall texture reference frame (depth=\(depthCopy != nil, privacy: .public))")
    }

    /// Average of every confident (medium+) depth reading in a frame — used to approximate "how
    /// far away is the wall, roughly" for the flat-plane sanity check in
    /// `ReconstructionEntityBuilder.wallPlane`. nil if there's no confident depth anywhere.
    private static func averageConfidentDepth(depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer?) -> Float? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard width > 0, height > 0 else { return nil }

        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceBytesPerRow = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        var sum: Double = 0
        var count = 0
        for y in 0..<height {
            let depthRow = depthBase.advanced(by: y * depthBytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let depth = depthRow[x]
                guard depth.isFinite, depth > 0 else { continue }
                if let confidenceBase {
                    let raw = (confidenceBase + y * confidenceBytesPerRow).assumingMemoryBound(to: UInt8.self)[x]
                    guard let level = ARConfidenceLevel(rawValue: Int(raw)), level.rawValue >= ARConfidenceLevel.medium.rawValue else {
                        continue
                    }
                }
                sum += Double(depth)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return Float(sum / Double(count))
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestFrame = frame
        let newQuality = Self.quality(for: frame.camera.trackingState)
        // Logged only on an actual CHANGE (not every frame) — cheap enum comparison, so this
        // doesn't reintroduce per-frame log spam, but gives a timeline of exactly when tracking
        // degraded/recovered relative to recording — useful alongside ARKit's own internal SLAM
        // diagnostics (e.g. "poor slam ... map_size(5)") for telling whether a crash lines up with
        // a tracking-quality drop or is unrelated to it.
        if newQuality != trackingQuality {
            DebugLog.tracking.info("Tracking quality \(String(describing: self.trackingQuality), privacy: .public) -> \(String(describing: newQuality), privacy: .public) at frame t=\(frame.timestamp, privacy: .public)")
        }
        trackingQuality = newQuality
        onFrameUpdate?(frame)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        ingest(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        ingest(anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let removedIDs = Set(anchors.compactMap { $0 as? ARMeshAnchor }.map { $0.identifier })
        guard !removedIDs.isEmpty else { return }
        meshAnchors.removeAll { removedIDs.contains($0.identifier) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DebugLog.tracking.error("ARSession failed: \(error.localizedDescription, privacy: .public)")
        trackingQuality = .notAvailable
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DebugLog.tracking.error("ARSession interrupted")
        trackingQuality = .notAvailable
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DebugLog.tracking.error("ARSession interruption ended — relocalizing (wall/body coordinate spaces may now be at risk)")
        trackingQuality = .relocalizing
    }

    private func ingest(_ anchors: [ARAnchor]) {
        let newMeshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !newMeshAnchors.isEmpty else { return }
        var byID = Dictionary(uniqueKeysWithValues: meshAnchors.map { ($0.identifier, $0) })
        for anchor in newMeshAnchors {
            byID[anchor.identifier] = anchor
        }
        meshAnchors = Array(byID.values)
    }

    private static func quality(for state: ARCamera.TrackingState) -> TrackingQuality {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .notAvailable
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return .limited("Move slower")
            case .insufficientFeatures: return .limited("Point at a more detailed area")
            case .initializing: return .limited("Hold steady — starting up")
            case .relocalizing: return .limited("Relocalizing — move slowly")
            @unknown default: return .limited("Hold steady")
            }
        }
    }

    /// Rough triangle count across all mesh anchors — the simple "scan progress" cue for Step 1.
    var estimatedTriangleCount: Int {
        meshAnchors.reduce(0) { $0 + $1.geometry.faces.count }
    }

    /// Fraction (0...1) of the CURRENT frame's depth grid with a confident (medium+) reading —
    /// a live "is this a good moment to tap Done Scanning" cue for Step 1. Directly answers the
    /// "did I scan enough" question: Step 4's wall is built from a SINGLE frame's depth grid (see
    /// `ReconstructionEntityBuilder.pointCloudWallEntity`), so the wall will have visible holes
    /// wherever THIS ratio is low at the moment the reference frame gets captured. nil if depth
    /// isn't available at all.
    static func depthConfidenceRatio(for frame: ARFrame?) -> Double? {
        guard let confidenceMap = frame?.sceneDepth?.confidenceMap else { return nil }
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(confidenceMap) else { return nil }
        let width = CVPixelBufferGetWidth(confidenceMap)
        let height = CVPixelBufferGetHeight(confidenceMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        guard width > 0, height > 0 else { return nil }

        var confidentCount = 0
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                if let level = ARConfidenceLevel(rawValue: Int(row[x])), level.rawValue >= ARConfidenceLevel.medium.rawValue {
                    confidentCount += 1
                }
            }
        }
        return Double(confidentCount) / Double(width * height)
    }

    /// Coarse `columns x rows` grid of average depth confidence (0...1), in the RAW confidence
    /// buffer's own orientation (landscape, native sensor layout — same raw space every other
    /// depth-pixel calculation in this app works in). Use `rotatedForCurrentOrientation` before
    /// displaying this on screen. nil if depth isn't available.
    ///
    /// This is a live, per-region approximation of "where does the depth sensor currently have
    /// good data" — NOT persistent full-wall coverage tracking like Apple's RoomPlan/Object
    /// Capture (which remember areas you've already scanned well even after you look away, via
    /// their own internal, unpublished capture-completeness logic). A true equivalent would need
    /// to raycast the accumulated mesh per screen region rather than just reading the current
    /// frame's confidence map — a bigger feature to build separately if this isn't enough signal.
    static func depthConfidenceGrid(for frame: ARFrame?, columns: Int, rows: Int) -> [[Double]]? {
        guard let confidenceMap = frame?.sceneDepth?.confidenceMap, columns > 0, rows > 0 else { return nil }
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(confidenceMap) else { return nil }
        let width = CVPixelBufferGetWidth(confidenceMap)
        let height = CVPixelBufferGetHeight(confidenceMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        guard width > 0, height > 0 else { return nil }

        var confidentCounts = [[Int]](repeating: [Int](repeating: 0, count: columns), count: rows)
        var totalCounts = [[Int]](repeating: [Int](repeating: 0, count: columns), count: rows)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let gridRow = min(rows - 1, y * rows / height)
            for x in 0..<width {
                let gridCol = min(columns - 1, x * columns / width)
                totalCounts[gridRow][gridCol] += 1
                if let level = ARConfidenceLevel(rawValue: Int(row[x])), level.rawValue >= ARConfidenceLevel.medium.rawValue {
                    confidentCounts[gridRow][gridCol] += 1
                }
            }
        }

        var grid = [[Double]](repeating: [Double](repeating: 0, count: columns), count: rows)
        for r in 0..<rows {
            for c in 0..<columns {
                grid[r][c] = totalCounts[r][c] > 0 ? Double(confidentCounts[r][c]) / Double(totalCounts[r][c]) : 0
            }
        }
        return grid
    }

    /// Rotates a RAW-buffer-space grid (from `depthConfidenceGrid`) to match the current device
    /// orientation, using the SAME landscape-native-sensor convention as
    /// `BodyPose3DExtractor.cameraOrientation()` (portrait needs a 90° rotation from the sensor's
    /// native landscape layout, landscapeRight needs 180°, etc.) — this is the standard,
    /// well-established relationship between a landscape-mounted rear camera sensor and the
    /// current UI orientation (the same one `AVCaptureConnection.videoOrientation` has used for
    /// years), not one of this file's other unverified sign-convention guesses. If this heatmap
    /// ever looks rotated relative to the real wall, `cameraOrientation()` almost certainly has
    /// the identical issue, since both derive from the same device-orientation switch.
    static func rotatedForCurrentOrientation(_ grid: [[Double]]) -> [[Double]] {
        func rotate90Clockwise(_ g: [[Double]]) -> [[Double]] {
            let rows = g.count
            guard rows > 0 else { return g }
            let columns = g[0].count
            var result = [[Double]](repeating: [Double](repeating: 0, count: rows), count: columns)
            for r in 0..<rows {
                for c in 0..<columns {
                    result[c][rows - 1 - r] = g[r][c]
                }
            }
            return result
        }

        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return grid // sensor's native orientation already
        case .landscapeRight:
            return rotate90Clockwise(rotate90Clockwise(grid)) // 180°
        case .portraitUpsideDown:
            return rotate90Clockwise(rotate90Clockwise(rotate90Clockwise(grid))) // 270°
        default: // .portrait, .faceUp, .faceDown, .unknown
            return rotate90Clockwise(grid) // 90°
        }
    }
}

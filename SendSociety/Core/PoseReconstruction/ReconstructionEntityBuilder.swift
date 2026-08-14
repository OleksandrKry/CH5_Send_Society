import RealityKit
import ARKit
import simd
import UIKit
import CoreImage

/// POSE-RECONSTRUCTION MODULE (the app's "core function"): everything in `Core/PoseReconstruction/`
/// is the actual climbing-analysis algorithm — Vision body detection, LiDAR grounding,
/// manual-pose-edit constraints, and turning all of that into renderable
/// RealityKit geometry. Nothing in this folder is SwiftUI; it takes plain data in (joint samples,
/// camera transforms, depth buffers) and hands plain data or RealityKit entities back out.
///
/// This is deliberately named differently from `Features/Reconstruction/` (the Step 4 SCREEN,
/// which only contains the SwiftUI view code) so the two are never confused in Xcode's navigator —
/// a frontend dev builds screens against this module's outputs; a backend dev changes how those
/// outputs are computed. `ReconstructionEntityBuilder` and `BodyPose3DExtractor` are this module's
/// two main entry points — most callers only ever need those two, not the smaller helper files.
///
/// Builds RealityKit entities for the Step 4 static reconstruction: the previously-scanned wall
/// mesh, and a single frame's body-pose skeleton, both placed in the SAME ARKit world coordinate
/// space they were captured in (both come from the one shared ARSession — see ARSessionManager).
enum ReconstructionEntityBuilder {

    // MARK: - Joint entity naming

    /// Every rendered joint sphere (see `skeletonEntity` below) is named `"joint.<rawValue>"` —
    /// purely for entity identification/debugging (e.g. inspecting the scene graph). Edit Pose's
    /// joint hit-testing (`ReconstructionSceneView.Coordinator.jointWithinRadius`) works off
    /// `currentPositions`' world coordinates directly (screen-projected radius check) rather than
    /// `ARView.entity(at:)` + this naming convention, since a fixed-visual-size entity hit test
    /// can't express "hit zone bigger than what's actually drawn."
    private static let jointEntityNamePrefix = "joint."

    private static func jointEntityName(for joint: BodyJointName) -> String {
        jointEntityNamePrefix + joint.rawValue
    }

    // MARK: - Wall mesh

    /// Builds the wall as one entity per mesh anchor. If a `textureReference` is available (the
    /// color frame captured when Step 1 scanning finished — see
    /// `ARSessionManager.captureWallTextureReference()`), each vertex is projected into that
    /// frame's image to get a UV coordinate, and the real captured photo is used as the surface
    /// texture — so the coach sees the actual wall/holds, not a placeholder color. Falls back to
    /// a flat lit gray material if there's no reference frame or texture generation fails for
    /// any reason.
    ///
    /// LIMITATION: this is a single-viewpoint projection, not multi-frame photogrammetry —
    /// surfaces the reference frame couldn't see well (steep angles, occluded areas, parts of
    /// the wall outside that one frame) will look stretched or wrong-colored rather than
    /// missing. Good enough to recognize the wall and holds; not photographically perfect.
    static func wallEntity(from anchors: [ARMeshAnchor], textureReference: ARSessionManager.WallTextureReference?) -> Entity {
        let root = Entity()
        let texturedMaterial = textureReference.flatMap(makeTexturedMaterial)
        if textureReference != nil && texturedMaterial == nil {
            DebugLog.reconstruction.error("Had a wall texture reference frame but failed to build a texture from it — falling back to flat gray wall")
        }

        var fallbackMaterial = SimpleMaterial(color: UIColor(white: 0.75, alpha: 1.0), roughness: 0.9, isMetallic: false)
        fallbackMaterial.faceCulling = .none

        // `??` doesn't work here — texturedMaterial and fallbackMaterial are different concrete
        // Material-conforming types, and `??` needs both sides to be the same type.
        let material: Material
        if let texturedMaterial {
            material = texturedMaterial
        } else {
            material = fallbackMaterial
        }

        // Prefer a dense, per-pixel point-cloud wall built straight from the reference frame's
        // raw LiDAR depth grid — it shows real surface relief (climbing hold bumps) as actual 3D
        // geometry, instead of ARKit's `ARMeshAnchor` mesh, which is fused/smoothed across many
        // frames for room-scale occlusion purposes and washes out anything under a few cm. Falls
        // back to the coarse anchor mesh if there's no depth for the reference frame, or the
        // point cloud comes out empty (e.g. the whole reference frame was low-confidence).
        if let textureReference, let pointCloud = pointCloudWallEntity(from: textureReference, material: material) {
            root.addChild(pointCloud)
            DebugLog.reconstruction.info("Wall entity built from dense point-cloud mesh (real bump relief), textured=\(texturedMaterial != nil, privacy: .public)")
            return root
        }

        for anchor in anchors {
            guard let mesh = try? meshResource(from: anchor.geometry, anchorTransform: anchor.transform, textureReference: texturedMaterial != nil ? textureReference : nil) else { continue }
            let modelEntity = ModelEntity(mesh: mesh, materials: [material])
            modelEntity.transform.matrix = anchor.transform
            root.addChild(modelEntity)
        }
        DebugLog.reconstruction.info("Wall entity built from \(anchors.count, privacy: .public) coarse mesh anchors (fallback — no usable depth grid), textured=\(texturedMaterial != nil, privacy: .public)")
        return root
    }

    // MARK: - Camera framing

    /// Straight-ahead distance (meters) from the camera to whatever the depth sensor saw directly
    /// in front of it for THIS frame — read from the center of the depth grid. Used ONLY to seed
    /// the initial 3D-view camera's zoom/angle (see `ReconstructionSceneView`'s camera setup), not
    /// for joint placement, so this deliberately skips the confidence filtering/hole-fill
    /// `BodyPose3DExtractor` uses for joints — a rough distance is enough to get the starting
    /// zoom/angle in the right ballpark, and precision matters far more for joints than for where
    /// the orbit camera starts out.
    static func centerDepthMeters(from context: BodyPose3DExtractor.DepthGroundingContext) -> Float? {
        let depthMap = context.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let x = width / 2
        let y = height / 2
        let value = (base + y * bytesPerRow).assumingMemoryBound(to: Float32.self)[x]
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Approximates "what point on the scanned wall mesh was the camera looking at" by searching
    /// every mesh vertex for the one closest to the ray cast forward from `origin`, restricted to
    /// a cone roughly matching a phone camera's field of view (so a stray vertex far off to the
    /// side can't win just for being close to the ray's *line* while nowhere near where the camera
    /// actually pointed). Fallback for camera framing when there's no per-frame depth map to
    /// sample directly (see `centerDepthMeters`) but the coarse `ARMeshAnchor` scan is available —
    /// e.g. an approximate/estimated reconstruction with no live depth.
    ///
    /// Ported from the CH5_Lidar_Testing sibling project's `MeshEntityBuilder.surfacePoint`, which
    /// validated this exact technique on device for matching the initial 3D-view camera to the
    /// real recording distance/angle — adapted here to read straight from `ARMeshAnchor.geometry`
    /// instead of that project's own `MeshArchive` vertex cache.
    static func surfacePoint(nearRayFrom origin: SIMD3<Float>, direction: SIMD3<Float>, in anchors: [ARMeshAnchor], maxAngleDegrees: Float = 30) -> SIMD3<Float>? {
        let length = simd_length(direction)
        guard length > 0.0001 else { return nil }
        let dir = direction / length
        let maxTan = tan(maxAngleDegrees * .pi / 180)

        var best: (point: SIMD3<Float>, perpDist: Float)?
        for anchor in anchors {
            let vertexSource = anchor.geometry.vertices
            let vertexPointer = vertexSource.buffer.contents()
            for i in 0..<vertexSource.count {
                let offset = vertexSource.offset + vertexSource.stride * i
                let local = (vertexPointer + offset).assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let world4 = anchor.transform * SIMD4<Float>(local, 1)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                let toVertex = world - origin
                let t = simd_dot(toVertex, dir)
                guard t > 0.05 else { continue } // behind/at the camera
                let perp = toVertex - dir * t
                let perpDist = simd_length(perp)
                guard perpDist <= t * maxTan else { continue } // outside the view cone
                if best == nil || perpDist < best!.perpDist {
                    best = (world, perpDist)
                }
            }
        }
        return best?.point
    }

    /// Builds the wall as a dense heightfield mesh triangulated directly from the reference
    /// frame's raw LiDAR depth grid — one vertex per depth pixel — rather than ARKit's fused,
    /// heavily-smoothed `ARMeshAnchor` triangulation. This is the same underlying idea as the
    /// point-cloud-from-depth-grid technique described in
    /// https://www.mdpi.com/1424-8220/23/19/8216 (Figure 3b): unproject each depth-grid cell to a
    /// 3D point using that single frame's camera pose + intrinsics, then connect neighboring
    /// cells into triangles.
    ///
    /// Because the color photo and the depth grid come from the SAME captured frame, UV mapping
    /// is a direct pixel-index lookup — no reprojection step, so no reprojection error (unlike
    /// `projectToUV`, which has to re-project the coarse mesh's independently-generated vertices).
    ///
    /// TRADE-OFF vs the coarse ARMeshAnchor wall: this only covers what was visible in the ONE
    /// frame captured when "Done Scanning" was tapped, not the full multi-angle scan area — so
    /// standing back far enough to see the whole wall in that one shot matters more now. In
    /// exchange, real relief (hold bumps) shows up as actual geometry instead of a flat surface
    /// with a photo painted on it.
    ///
    /// UNVERIFIED ON DEVICE: the depth-grid resolution on LiDAR iPads is roughly 256×192 — far
    /// lower than the color image — so very small/thin holds may still be under-resolved. The
    /// camera-space sign convention (Y/Z negation below) mirrors
    /// `BodyPose3DExtractor.lidarGroundedCameraSpacePosition`, which is itself flagged unverified;
    /// if the wall renders mirrored, inside-out, or facing away, that shared convention is the
    /// first thing to check (though `faceCulling = .none` on both materials means a backwards
    /// triangle winding alone won't make it invisible).
    ///
    /// Returns nil (caller falls back to the coarse mesh) if there's no depth map, or zero valid
    /// triangles survive the confidence/discontinuity filtering.
    static func pointCloudWallEntity(from reference: ARSessionManager.WallTextureReference, material: Material) -> Entity? {
        guard let depthMap = reference.depthMap else { return nil }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard depthWidth > 1, depthHeight > 1 else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        let confidenceMap = reference.confidenceMap
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

        func rawDepth(_ x: Int, _ y: Int) -> Float? {
            guard x >= 0, x < depthWidth, y >= 0, y < depthHeight else { return nil }
            let value = (depthBase + y * depthBytesPerRow).assumingMemoryBound(to: Float32.self)[x]
            guard value.isFinite, value > 0 else { return nil }
            if let confidenceBase {
                let raw = (confidenceBase + y * confidenceBytesPerRow).assumingMemoryBound(to: UInt8.self)[x]
                guard let level = ARConfidenceLevel(rawValue: Int(raw)), level.rawValue >= ARConfidenceLevel.medium.rawValue else {
                    return nil
                }
            }
            return value
        }

        // Small hole-fill: scattered per-pixel confidence dropout is common over dark or
        // reflective surfaces — exactly what climbing holds often are — so a single failed pixel
        // shouldn't punch a hole in the mesh if a confident reading exists one or two pixels
        // away. Same idea as the grid-neighbor-averaging technique in
        // https://www.mdpi.com/1424-8220/23/19/8216.
        func depthAt(_ x: Int, _ y: Int) -> Float? {
            if let direct = rawDepth(x, y) { return direct }
            var best: (depth: Float, distSq: Int)?
            let maxRadius = 2
            for radius in 1...maxRadius {
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        guard max(abs(dx), abs(dy)) == radius else { continue }
                        guard let depth = rawDepth(x + dx, y + dy) else { continue }
                        let distSq = dx * dx + dy * dy
                        if best == nil || distSq < best!.distSq {
                            best = (depth, distSq)
                        }
                    }
                }
                if best != nil { break }
            }
            return best?.depth
        }

        // `intrinsics` is for the COLOR image resolution; scale down to the (much lower-res)
        // depth grid's pixel dimensions.
        let scaleX = Float(depthWidth) / Float(reference.imageResolution.width)
        let scaleY = Float(depthHeight) / Float(reference.imageResolution.height)
        let fx = reference.intrinsics.columns.0.x * scaleX
        let fy = reference.intrinsics.columns.1.y * scaleY
        let cx = reference.intrinsics.columns.2.x * scaleX
        let cy = reference.intrinsics.columns.2.y * scaleY

        // Unproject every confident depth pixel to an ARKit world-space point. `nil` marks a
        // pixel with no usable depth reading (hole in the grid).
        var worldPoints = [SIMD3<Float>?](repeating: nil, count: depthWidth * depthHeight)
        var depths = [Float?](repeating: nil, count: depthWidth * depthHeight)
        for y in 0..<depthHeight {
            for x in 0..<depthWidth {
                guard let depth = depthAt(x, y) else { continue }
                // Standard pixel-projection convention (X-right, Y-down, Z-forward) -> ARKit
                // camera convention (X-right, Y-up, Z-backward).
                let xCV = (Float(x) + 0.5 - cx) * depth / fx
                let yCV = (Float(y) + 0.5 - cy) * depth / fy
                let cameraSpace = SIMD3<Float>(xCV, -yCV, -depth)
                let world4 = reference.cameraTransform * SIMD4<Float>(cameraSpace, 1)
                let index = y * depthWidth + x
                worldPoints[index] = SIMD3<Float>(world4.x, world4.y, world4.z)
                depths[index] = depth
            }
        }

        // One mesh vertex per valid pixel, with a pixel-exact UV (same frame as the color photo,
        // so no reprojection needed).
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(depthWidth * depthHeight)
        uvs.reserveCapacity(depthWidth * depthHeight)
        var vertexIndex = [Int](repeating: -1, count: depthWidth * depthHeight)
        for y in 0..<depthHeight {
            for x in 0..<depthWidth {
                let index = y * depthWidth + x
                guard let point = worldPoints[index] else { continue }
                vertexIndex[index] = positions.count
                positions.append(point)
                // V flipped (`1 - ...`): RealityKit's texture V origin doesn't match the depth
                // grid's row order (y=0 = top row) 1:1, so leaving this unflipped renders the wall
                // photo mirrored top-to-bottom vs. how it actually looks in person — confirmed and
                // fixed the same way in the LidarCalibTest sibling project's MeshEntityBuilder.
                let normalizedV = (Float(y) + 0.5) / Float(depthHeight)
                uvs.append(SIMD2<Float>((Float(x) + 0.5) / Float(depthWidth), 1 - normalizedV))
            }
        }

        // Reject a quad if its four corners' depths disagree too much — almost always the wall's
        // silhouette edge against the background/floor, not real wall surface; bridging it would
        // draw a stretched, wrong-colored skin connecting the two.
        func hasDiscontinuity(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Bool {
            let values = [a, b, c, d]
            let maxV = values.max()!, minV = values.min()!
            return (maxV - minV) > max(0.05, minV * 0.08)
        }

        var indices: [UInt32] = []
        for y in 0..<(depthHeight - 1) {
            for x in 0..<(depthWidth - 1) {
                let iTL = y * depthWidth + x
                let iTR = y * depthWidth + x + 1
                let iBL = (y + 1) * depthWidth + x
                let iBR = (y + 1) * depthWidth + x + 1
                guard vertexIndex[iTL] >= 0, vertexIndex[iTR] >= 0, vertexIndex[iBL] >= 0, vertexIndex[iBR] >= 0,
                      let dTL = depths[iTL], let dTR = depths[iTR], let dBL = depths[iBL], let dBR = depths[iBR]
                else { continue }
                if hasDiscontinuity(dTL, dTR, dBL, dBR) { continue }

                let vTL = UInt32(vertexIndex[iTL]), vTR = UInt32(vertexIndex[iTR])
                let vBL = UInt32(vertexIndex[iBL]), vBR = UInt32(vertexIndex[iBR])
                indices.append(contentsOf: [vTL, vBL, vTR])
                indices.append(contentsOf: [vTR, vBL, vBR])
            }
        }

        guard !indices.isEmpty else {
            DebugLog.reconstruction.error("Point-cloud wall produced zero valid triangles — falling back to coarse mesh")
            return nil
        }

        var descriptor = MeshDescriptor(name: "wallPointCloud")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)

        guard let mesh = try? MeshResource.generate(from: [descriptor]) else {
            DebugLog.reconstruction.error("MeshResource.generate failed for point-cloud wall — falling back to coarse mesh")
            return nil
        }

        let entity = ModelEntity(mesh: mesh, materials: [material])
        DebugLog.reconstruction.info("Point-cloud wall built: \(positions.count, privacy: .public) vertices, \(indices.count / 3, privacy: .public) triangles from a \(depthWidth, privacy: .public)x\(depthHeight, privacy: .public) depth grid")
        return entity
    }

    /// Converts the reference frame's captured color image into a RealityKit texture. Returns
    /// nil (triggering the flat-gray fallback) on any failure rather than throwing, since a
    /// texture problem shouldn't take down the whole reconstruction screen.
    private static func makeTexturedMaterial(from reference: ARSessionManager.WallTextureReference) -> UnlitMaterial? {
        let ciImage = CIImage(cvPixelBuffer: reference.colorImage)
        guard let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        do {
            let texture = try TextureResource.generate(from: cgImage, options: .init(semantic: .color))
            var material = UnlitMaterial()
            // The captured photo already has real-world lighting baked into its pixels, so this
            // is deliberately Unlit — running it through the scene's DirectionalLight/shading on
            // top would double up the lighting and look wrong.
            material.color = .init(texture: .init(texture))
            material.faceCulling = .none
            return material
        } catch {
            DebugLog.reconstruction.error("TextureResource.generate failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func meshResource(
        from geometry: ARMeshGeometry,
        anchorTransform: simd_float4x4,
        textureReference: ARSessionManager.WallTextureReference?
    ) throws -> MeshResource {
        let vertexSource = geometry.vertices
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertexSource.count)
        let vertexPointer = vertexSource.buffer.contents()
        for i in 0..<vertexSource.count {
            let offset = vertexSource.offset + vertexSource.stride * i
            let vertex = (vertexPointer + offset).assumingMemoryBound(to: SIMD3<Float>.self).pointee
            positions.append(vertex)
        }

        let faceElement = geometry.faces
        var indices: [UInt32] = []
        let totalIndices = faceElement.count * faceElement.indexCountPerPrimitive
        indices.reserveCapacity(totalIndices)
        let facePointer = faceElement.buffer.contents()
        let indexSize = faceElement.bytesPerIndex
        for i in 0..<totalIndices {
            let offset = i * indexSize
            if indexSize == 2 {
                let value = (facePointer + offset).assumingMemoryBound(to: UInt16.self).pointee
                indices.append(UInt32(value))
            } else {
                let value = (facePointer + offset).assumingMemoryBound(to: UInt32.self).pointee
                indices.append(value)
            }
        }

        var descriptor = MeshDescriptor(name: "wallMesh")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)

        if let textureReference {
            // UV per vertex: project the vertex (converted from anchor-local to world space)
            // through the reference frame's camera. Vertices are stored in the mesh anchor's
            // LOCAL space, so multiply by anchorTransform first.
            var uvs: [SIMD2<Float>] = []
            uvs.reserveCapacity(positions.count)
            for local in positions {
                let world4 = anchorTransform * SIMD4<Float>(local.x, local.y, local.z, 1)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                uvs.append(projectToUV(worldPosition: world, reference: textureReference))
            }
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        }

        return try MeshResource.generate(from: [descriptor])
    }

    /// Projects a world-space point into the reference frame's image and returns a UV coordinate
    /// clamped to [0,1] (rather than an optional) so every vertex gets some UV even for points
    /// that are behind/outside the reference camera's view — those will just sample a
    /// wrong-but-bounded pixel rather than needing special-case handling in the mesh descriptor.
    ///
    /// V is flipped below (`1 - ...`) to match the same fix applied to `pointCloudWallEntity`'s UV
    /// computation — confirmed and fixed in the LidarCalibTest sibling project (the wall photo
    /// rendered mirrored top-to-bottom without it).
    ///
    /// UNVERIFIED ON DEVICE: the ARKit-camera-space -> pixel-projection conversion (Y and Z
    /// negation) mirrors the same one in `BodyPose3DExtractor.lidarScaleCorrection`, which itself
    /// is unverified.
    private static func projectToUV(worldPosition: SIMD3<Float>, reference: ARSessionManager.WallTextureReference) -> SIMD2<Float> {
        // cameraTransform is camera-to-world; invert to go world -> reference camera space.
        let cameraSpace4 = reference.cameraTransform.inverse * SIMD4<Float>(worldPosition, 1)
        // ARKit camera space: X-right, Y-up, Z-backward. Convert to the standard pixel-
        // projection convention (X-right, Y-down, Z-forward-positive).
        let xCV = cameraSpace4.x
        let yCV = -cameraSpace4.y
        let zCV = -cameraSpace4.z
        let safeZ = zCV > 0.05 ? zCV : 0.05 // avoid divide-by-zero for points behind the camera

        let fx = reference.intrinsics.columns.0.x
        let fy = reference.intrinsics.columns.1.y
        let cx = reference.intrinsics.columns.2.x
        let cy = reference.intrinsics.columns.2.y
        let width = Float(reference.imageResolution.width)
        let height = Float(reference.imageResolution.height)

        let u = fx * xCV / safeZ + cx
        let v = fy * yCV / safeZ + cy
        let normalizedU = min(max(u / width, 0), 1)
        let normalizedV = min(max(v / height, 0), 1)
        return SIMD2<Float>(normalizedU, 1 - normalizedV)
    }

    // MARK: - Skeleton

    /// World-space position of every detected joint. Exposed separately (not just buried inside
    /// `skeletonEntity`) so callers — e.g. ReconstructionView's camera-framing code — can use the
    /// same positions without recomputing them.
    ///
    /// When `depthContext` is available (the recorded frame had real LiDAR depth), the WHOLE
    /// skeleton is grounded via a single trusted anchor — the hip/root joint — through
    /// `BodyPose3DExtractor.groundSkeletonRootAnchored`: the hip's real LiDAR depth vs. Vision's
    /// own depth guess for the hip gives a scale factor, and every other joint's Vision-estimated
    /// offset from the hip is scaled by that SAME factor, uniformly in all three axes. This is
    /// what fixes both the climber-height accuracy and the skeleton-vs-wall placement (the wall
    /// mesh is built from the SAME depth data, so grounding the skeleton in it puts both in a
    /// consistent, real-world-scaled coordinate space instead of Vision's own, less reliable,
    /// depth guess) — see that function's doc comment for why this replaced an earlier version
    /// that grounded every joint independently (it couldn't guarantee bone lengths stayed
    /// physically plausible). Falls back to the ungrounded, Vision-only estimate for every joint
    /// when there's no depth data for this frame at all, OR when the hip's own LiDAR reading fails
    /// its sanity check.
    ///
    /// `wallReference`, when available, is used as a final sanity pass (`keepInFrontOfWall`) —
    /// the wall's point-cloud mesh and the skeleton are grounded from DIFFERENT frames (Step 1's
    /// single reference frame vs. the paused Step 3 frame), so any tracking drift or depth noise
    /// between those two moments can leave a joint positioned behind the wall's own reconstructed
    /// surface, which is physically impossible for a climber actually on the wall.
    static func worldJointPositions(
        from sample: BodyPoseSample,
        cameraTransform: simd_float4x4,
        depthContext: BodyPose3DExtractor.DepthGroundingContext? = nil,
        wallReference: ARSessionManager.WallTextureReference? = nil
    ) -> [BodyJointName: SIMD3<Float>] {
        guard let depthContext else {
            DebugLog.reconstruction.info("Step 4 skeleton placed using Vision-only estimate (no depth data for this frame)")
            var worldPositions: [BodyJointName: SIMD3<Float>] = [:]
            for (joint, local) in sample.rootRelativePositions {
                worldPositions[joint] = BodyPose3DExtractor.worldPosition(
                    rootRelative: local,
                    cameraOriginMatrix: sample.cameraOriginMatrix,
                    cameraTransform: cameraTransform
                )
            }
            return keepInFrontOfWall(worldPositions, wallReference: wallReference)
        }

        // Ground the hip in real LiDAR depth, then scale every other joint's Vision-estimated
        // offset from the hip by that same factor — see `groundSkeletonRootAnchored`'s doc comment
        // for why this replaced independently grounding all 17 joints.
        let (grounded, isRootGrounded) = BodyPose3DExtractor.groundSkeletonRootAnchored(
            sample.rootRelativePositions,
            cameraOriginMatrix: sample.cameraOriginMatrix,
            context: depthContext
        )
        if isRootGrounded {
            DebugLog.reconstruction.info("Step 4 skeleton placed using root-anchored LiDAR scale (hip grounded, \(grounded.count, privacy: .public) joints scaled to match)")
        } else {
            DebugLog.reconstruction.info("Step 4 skeleton placed using Vision-only estimate (hip LiDAR grounding unavailable or failed its sanity check)")
        }
        var worldPositions: [BodyJointName: SIMD3<Float>] = [:]
        for (joint, cameraSpace) in grounded {
            worldPositions[joint] = BodyPose3DExtractor.worldPosition(cameraSpace: cameraSpace, cameraTransform: cameraTransform)
        }
        return keepInFrontOfWall(worldPositions, wallReference: wallReference)
    }

    /// A crude flat-plane approximation of the wall, derived from the SAME single reference frame
    /// the wall's point-cloud mesh/texture come from: a point at the reference camera's position
    /// plus its forward direction times the reference frame's average measured depth, with the
    /// plane's "in front" normal pointing back toward that camera. This is NOT a precise fit to
    /// the wall's real (possibly non-planar, hold-covered) surface — it's only accurate enough to
    /// answer "roughly which side of the wall is the climbing side."
    private static func wallPlane(from reference: ARSessionManager.WallTextureReference) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard let averageDepth = reference.averageDepth, averageDepth > 0 else { return nil }
        let cameraPosition = SIMD3<Float>(reference.cameraTransform.columns.3.x, reference.cameraTransform.columns.3.y, reference.cameraTransform.columns.3.z)
        // ARKit's camera looks down its own -Z; world-space forward = the transform applied to
        // the direction (0,0,-1).
        let forward4 = reference.cameraTransform * SIMD4<Float>(0, 0, -1, 0)
        let forward = normalize(SIMD3<Float>(forward4.x, forward4.y, forward4.z))
        let planePoint = cameraPosition + forward * averageDepth
        let planeNormal = -forward // points back toward the camera — the "climbing" side
        return (planePoint, planeNormal)
    }

    /// Pushes any joint that ended up at or behind the wall plane back in front of it by
    /// `margin`. A climber's body is, physically, always in front of the wall they're on — if
    /// grounding noise puts a joint behind the wall's own reconstructed surface, the exact cause
    /// (tracking drift between Step 1 and Step 3, wall-vs-skeleton frame mismatch, residual depth
    /// error) matters less than the fact that the result is physically impossible, so this is a
    /// deliberately blunt correction rather than a subtle one. Does nothing if there's no wall
    /// reference or its depth data was unavailable.
    private static func keepInFrontOfWall(
        _ positions: [BodyJointName: SIMD3<Float>],
        wallReference: ARSessionManager.WallTextureReference?,
        margin: Float = 0.08
    ) -> [BodyJointName: SIMD3<Float>] {
        guard let wallReference, let plane = wallPlane(from: wallReference) else { return positions }
        var corrected = positions
        var pushedCount = 0
        for (joint, position) in positions {
            let signedDistance = simd_dot(position - plane.point, plane.normal)
            if signedDistance < margin {
                corrected[joint] = position + plane.normal * (margin - signedDistance)
                pushedCount += 1
            }
        }
        if pushedCount > 0 {
            DebugLog.reconstruction.info("Pushed \(pushedCount, privacy: .public)/\(positions.count, privacy: .public) joints back in front of the wall plane")
        }
        return corrected
    }

    static func skeletonEntity(
        /// Optional (unlike `worldJointPositions`'s required `sample`) so a saved session review
        /// can render a previously-generated reconstruction via `overridePositions` alone, without
        /// re-running Vision — see `RecordingSession`/`ReconstructionEntry`'s doc comments for why
        /// that data can't be regenerated after the fact. Only actually read when
        /// `overridePositions` is nil; `??`'s right side is lazily evaluated, so passing nil here
        /// is safe as long as `overridePositions` is provided.
        from sample: BodyPoseSample?,
        cameraTransform: simd_float4x4,
        depthContext: BodyPose3DExtractor.DepthGroundingContext? = nil,
        wallReference: ARSessionManager.WallTextureReference? = nil,
        /// When present, used INSTEAD of the auto-detected/grounded positions below — the coach's
        /// manually-dragged pose (see `SkeletonPoseEditor`). Passing nil (the default) preserves
        /// the original auto-only behavior exactly.
        overridePositions: [BodyJointName: SIMD3<Float>]? = nil,
        /// Joints/bones about to be affected by an in-progress drag (see
        /// `SkeletonPoseEditor.impactedJoints`/`impactedBones`) — rendered in a distinct highlight
        /// color so the coach can see what will move BEFORE releasing the drag, not just after.
        highlightedJoints: Set<BodyJointName> = [],
        highlightedBones: Set<SkeletonBone> = [],
        /// True while the coach is in pose-editing mode — skips the mannequin body wrapper so the
        /// bare yellow joints/red bones are fully exposed and easy to grab, instead of being
        /// partly buried inside the (visually larger) mannequin capsules.
        hideMannequinBody: Bool = false
    ) -> Entity {
        let root = Entity()
        // Unlit (not affected by scene lighting) and bright, so the climber's body stays clearly
        // visible regardless of how the wall's lit material renders — this is the thing the
        // coach is actually here to look at.
        let jointMaterial = UnlitMaterial(color: .systemYellow)
        let boneMaterial = UnlitMaterial(color: .systemRed)
        // Distinct from every other color already in use (yellow joints, red bones, teal preset
        // grips/feet, tan mannequin) so "this is about to move" reads unambiguously during a drag.
        let highlightJointMaterial = UnlitMaterial(color: .systemGreen)
        let highlightBoneMaterial = UnlitMaterial(color: .systemGreen)
        var mannequinMaterial = SimpleMaterial(color: UIColor(red: 0.86, green: 0.71, blue: 0.6, alpha: 0.92), roughness: 0.7, isMetallic: false)
        mannequinMaterial.faceCulling = .none

        let worldPositions = overridePositions ?? sample.map {
            worldJointPositions(from: $0, cameraTransform: cameraTransform, depthContext: depthContext, wallReference: wallReference)
        } ?? [:]

        // Mannequin body: a rough capsule "wrapper" around each bone, sized per body part, so the
        // coach sees an actual humanoid volume instead of a bare stick figure. Purely a visual
        // approximation — capsule radii are fixed anatomical guesses, not measured from this
        // specific climber. Skipped in pose-editing mode — see `hideMannequinBody`'s doc comment.
        if !hideMannequinBody {
            for bone in skeletonBones {
                guard let a = worldPositions[bone.from], let b = worldPositions[bone.to] else { continue }
                if let capsule = cylinderBetween(a, b, radius: mannequinRadius(for: bone), material: mannequinMaterial) {
                    root.addChild(capsule)
                }
            }
            // Cover the flat cylinder end caps at each joint with a sphere sized to the thickest
            // connected limb, so the mannequin reads as one continuous body instead of a set of
            // separate rod segments meeting at visible seams.
            for joint in worldPositions.keys {
                guard let position = worldPositions[joint] else { continue }
                let radius = mannequinJointRadius(at: joint)
                let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [mannequinMaterial])
                sphere.position = position
                root.addChild(sphere)
            }
        }

        for (joint, position) in worldPositions {
            let isHighlighted = highlightedJoints.contains(joint)
            // Slightly larger when highlighted — both a clearer visual cue and a bigger hit
            // target for the joint that's actively being dragged.
            let radius: Float = isHighlighted ? 0.045 : 0.035
            let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [isHighlighted ? highlightJointMaterial : jointMaterial])
            sphere.position = position
            sphere.name = jointEntityName(for: joint)
            // REQUIRED for `ARView.entity(at:)` (used by the Edit Pose drag gesture) to ever hit
            // this sphere at all — RealityKit's hit-testing only considers entities with a
            // collision shape, never bare render geometry. Without this, every tap-and-drag on a
            // joint silently misses and falls through to the ordinary camera-orbit gesture, which
            // looks exactly like "dragging a joint just rotates the camera instead."
            sphere.generateCollisionShapes(recursive: false)
            root.addChild(sphere)
        }

        for bone in skeletonBones {
            guard let a = worldPositions[bone.from], let b = worldPositions[bone.to] else { continue }
            let isHighlighted = highlightedBones.contains(bone)
            let radius: Float = isHighlighted ? 0.022 : 0.016
            if let boneEntity = cylinderBetween(a, b, radius: radius, material: isHighlighted ? highlightBoneMaterial : boneMaterial) {
                root.addChild(boneEntity)
            }
        }

        DebugLog.reconstruction.info("Skeleton entity built with \(worldPositions.count, privacy: .public)/17 joints resolved")
        return root
    }

    /// Fixed per-body-part capsule radius for the mannequin wrapper — anatomically plausible
    /// guesses, not measurements. Anything not explicitly listed (shouldn't happen given
    /// `skeletonBones`, but kept exhaustive-safe) gets a thin default.
    private static func mannequinRadius(for bone: SkeletonBone) -> Float {
        switch (bone.from, bone.to) {
        case (.root, .spine), (.spine, .centerShoulder):
            return 0.11 // torso
        case (.centerShoulder, .leftShoulder), (.centerShoulder, .rightShoulder):
            return 0.07 // shoulder girdle
        case (.leftShoulder, .leftElbow), (.rightShoulder, .rightElbow):
            return 0.05 // upper arm
        case (.leftElbow, .leftWrist), (.rightElbow, .rightWrist):
            return 0.04 // forearm
        case (.centerShoulder, .centerHead):
            return 0.045 // neck
        case (.centerHead, .topHead):
            return 0.09 // head
        case (.root, .leftHip), (.root, .rightHip):
            return 0.09 // pelvis
        case (.leftHip, .leftKnee), (.rightHip, .rightKnee):
            return 0.07 // thigh
        case (.leftKnee, .leftAnkle), (.rightKnee, .rightAnkle):
            return 0.05 // shin
        default:
            return 0.04
        }
    }

    /// Largest mannequin radius among the bones touching `joint` — used to size the joint-cap
    /// sphere so it fully covers the thickest connected limb's cylinder end.
    private static func mannequinJointRadius(at joint: BodyJointName) -> Float {
        var maxRadius: Float = 0.03
        for bone in skeletonBones where bone.from == joint || bone.to == joint {
            maxRadius = max(maxRadius, mannequinRadius(for: bone))
        }
        return maxRadius
    }

    /// Builds a cylinder mesh stretching from `a` to `b` and rotates it to point the right way —
    /// used for BOTH the thin red skeleton bones AND the thicker tan mannequin limb "capsules"
    /// (there's no real capsule mesh here: `MeshResource.generateCapsule` doesn't exist on this
    /// RealityKit version, confirmed by a real build error, so a plain cylinder stands in for one
    /// in both places — they used to be two separate, identical copies of this same function).
    /// For the mannequin case, the rounded-off look comes from `skeletonEntity` also dropping a
    /// sphere at every joint (see `mannequinJointRadius`) sized to match the thickest connected
    /// limb, which covers the flat cylinder end caps instead of leaving visible seams at the
    /// joints.
    private static func cylinderBetween(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: Float, material: Material) -> Entity? {
        let distance = simd_distance(a, b)
        guard distance > 0.001 else { return nil }
        let mesh = MeshResource.generateCylinder(height: distance, radius: radius)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = (a + b) / 2

        // Cylinders are generated along +Y by default; rotate +Y onto the a->b direction.
        let direction = normalize(b - a)
        let up = SIMD3<Float>(0, 1, 0)
        let dot = simd_dot(up, direction)
        if dot < -0.9999 {
            entity.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        } else if dot < 0.9999 {
            let axis = normalize(simd_cross(up, direction))
            let angle = acos(dot)
            entity.orientation = simd_quatf(angle: angle, axis: axis)
        }
        return entity
    }
}

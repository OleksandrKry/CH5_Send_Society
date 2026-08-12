import RealityKit
import ARKit
import simd
import UIKit
import CoreImage

/// POSE-RECONSTRUCTION MODULE (the app's "core function"): everything in `Core/PoseReconstruction/`
/// is the actual climbing-analysis algorithm — Vision body/hand detection, LiDAR grounding,
/// grip/foot classification, manual-pose-edit constraints, and turning all of that into renderable
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

    /// Every rendered joint sphere (see `skeletonEntity` below) is named `"joint.<rawValue>"` so
    /// `ReconstructionSceneView.Coordinator`'s Edit Pose drag gesture can hit-test `ARView.entity
    /// (at:)`'s result back to a `BodyJointName` — this is the one place both the writer (here) and
    /// the reader (`Coordinator.jointHit`) agree on that naming convention, so it's never duplicated
    /// as a raw string literal in the SwiftUI-side gesture code.
    private static let jointEntityNamePrefix = "joint."

    private static func jointEntityName(for joint: BodyJointName) -> String {
        jointEntityNamePrefix + joint.rawValue
    }

    /// Parses an `Entity.name` produced by `jointEntityName(for:)` back into a `BodyJointName` —
    /// nil for any entity that isn't a joint sphere (the wall, bones, hand/foot presets, etc. all
    /// have different names).
    static func jointName(fromEntityName entityName: String) -> BodyJointName? {
        guard entityName.hasPrefix(jointEntityNamePrefix) else { return nil }
        return BodyJointName(rawValue: String(entityName.dropFirst(jointEntityNamePrefix.count)))
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
    /// When `depthContext` is available (the recorded frame had real LiDAR depth), every joint
    /// that CAN be grounded in that real depth is, via `BodyPose3DExtractor.groundJointsBestEffort`
    /// — this is what fixes both the climber-height accuracy and the skeleton-vs-wall placement
    /// (the wall mesh is built from the SAME depth data, so grounding the skeleton in it puts both
    /// in a consistent, real-world-scaled coordinate space instead of Vision's own, less reliable,
    /// depth guess). Only the specific joint(s) that fail to ground (e.g. an occluded hand) fall
    /// back to Vision's own estimate — see `groundJointsBestEffort`'s doc comment for why an
    /// all-or-nothing per-frame result would be worse. Falls back to the ungrounded, Vision-only
    /// estimate for every joint only when there's no depth data for this frame at all.
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

        // Best-effort, not all-or-nothing: keep real LiDAR grounding for every joint that succeeds,
        // and only fall back to Vision's own (less accurate) estimate for whichever SPECIFIC
        // joint(s) fail — see `groundJointsBestEffort`'s doc comment for why throwing away every
        // other joint's real depth over one bad reading (e.g. a hand's confidence-dropout search
        // grabbing the wall behind it) was making the WHOLE skeleton visibly worse than necessary.
        let (grounded, ungroundedJoints) = BodyPose3DExtractor.groundJointsBestEffort(
            sample.rootRelativePositions,
            cameraOriginMatrix: sample.cameraOriginMatrix,
            context: depthContext
        )
        if ungroundedJoints.isEmpty {
            DebugLog.reconstruction.info("Step 4 skeleton placed using LiDAR-grounded joint depth (17/17 joints)")
        } else {
            let resolved = sample.rootRelativePositions.count - ungroundedJoints.count
            DebugLog.reconstruction.info("Step 4 skeleton placed using LiDAR-grounded joint depth (\(resolved)/\(sample.rootRelativePositions.count) joints — the rest used Vision-only, see prior warning for which)")
        }
        var worldPositions: [BodyJointName: SIMD3<Float>] = [:]
        for (joint, cameraSpace) in grounded {
            worldPositions[joint] = BodyPose3DExtractor.worldPosition(cameraSpace: cameraSpace, cameraTransform: cameraTransform)
        }
        return keepInFrontOfWall(worldPositions, wallReference: wallReference)
    }

    /// YOLO-backend equivalent of `worldJointPositions(from:cameraTransform:depthContext:
    /// wallReference:)` above — takes joints already known in RAW PIXEL space
    /// (`BodyPose3DExtractor.groundPixelJoints`'s expected input, matching `YOLOBodyPoseDetector`
    /// 's native output) instead of deriving them from a Vision `BodyPoseSample`'s rootRelative/
    /// cameraOriginMatrix shape. Applies the same `keepInFrontOfWall` safety pass as the Vision
    /// path.
    ///
    /// UNLIKE the Vision version, there is no "fall back to a less-accurate whole-frame estimate
    /// when there's no depth" case — YOLO has no non-depth 3D estimate to fall back to at all
    /// (see `BodyPose3DExtractor.groundPixelJoints`'s doc comment), so `depthContext` is required
    /// here, not optional, and a joint that doesn't ground is simply absent from the result.
    static func worldJointPositions(
        fromPixelJoints pixelJoints: [BodyJointName: CGPoint],
        cameraTransform: simd_float4x4,
        depthContext: BodyPose3DExtractor.DepthGroundingContext,
        wallReference: ARSessionManager.WallTextureReference? = nil
    ) -> [BodyJointName: SIMD3<Float>] {
        let grounded = BodyPose3DExtractor.groundPixelJoints(pixelJoints, context: depthContext)
        var worldPositions: [BodyJointName: SIMD3<Float>] = [:]
        for (joint, cameraSpace) in grounded {
            worldPositions[joint] = BodyPose3DExtractor.worldPosition(cameraSpace: cameraSpace, cameraTransform: cameraTransform)
        }
        return keepInFrontOfWall(worldPositions, wallReference: wallReference)
    }

    /// Hybrid backend, for `ReconstructionEstimator`'s "Estimate 3D" path ONLY (never Step 4
    /// Generate or Calibration): YOLO supplies joint PIXEL positions (per the user's explicit
    /// choice — YOLO's skeleton/bone detection is more reliable than Vision's own 2D estimate),
    /// while Vision's own (non-LiDAR) 3D pose estimate supplies the per-joint DEPTH that YOLO has
    /// no way to produce on its own — see `BodyPose3DExtractor.visionEstimatedDepths`/
    /// `unprojectWithExternalDepth`, which this is a thin wrapper around. `intrinsics` here is the
    /// wall's archived reference-frame intrinsics (`ARSessionManager.WallTextureReference
    /// .intrinsics`) — valid to reuse because the recorded video is written directly from
    /// `ARFrame.capturedImage` (see `VideoRecorder`), the exact same raw sensor buffer/resolution
    /// the wall reference frame's intrinsics were captured against.
    static func worldJointPositions(
        fromPixelJoints pixelJoints: [BodyJointName: CGPoint],
        visionDepths: [BodyJointName: Float],
        intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4,
        wallReference: ARSessionManager.WallTextureReference? = nil
    ) -> [BodyJointName: SIMD3<Float>] {
        let grounded = BodyPose3DExtractor.unprojectWithExternalDepth(pixelJoints, depths: visionDepths, intrinsics: intrinsics)
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

    /// Runs grip/foot-placement classification for both hands and both feet against a single
    /// frame's already-grounded skeleton + hand data — see `GripClassifier` for the classification
    /// logic and why it exists at all instead of raw finger/toe reconstruction. Exposed separately
    /// from `skeletonEntity` (not buried inside it) so `ContentView.ReconstructionHost`'s
    /// nearby-frame fallback can run this same classification against CANDIDATE frames too, not
    /// just the one that ends up rendered — mirroring the existing raw-hand-detection fallback
    /// pattern.
    static func classifyGripsAndFeet(
        poseSample: BodyPoseSample,
        cameraTransform: simd_float4x4,
        depthContext: BodyPose3DExtractor.DepthGroundingContext?,
        handSample: HandPoseSample?,
        handCameraTransform: simd_float4x4?,
        wallReference: ARSessionManager.WallTextureReference?
    ) -> (leftHand: GripClassification?, rightHand: GripClassification?, leftFoot: FootClassification?, rightFoot: FootClassification?) {
        let worldPositions = worldJointPositions(from: poseSample, cameraTransform: cameraTransform, depthContext: depthContext, wallReference: wallReference)
        return classifyGripsAndFeet(
            worldPositions: worldPositions,
            handSample: handSample,
            handCameraTransform: handCameraTransform,
            cameraTransform: cameraTransform,
            wallReference: wallReference
        )
    }

    /// Same classification as the `poseSample`-based overload above, for callers that already
    /// have FINAL world-space joint positions instead of a Vision `BodyPoseSample` to derive them
    /// from — used by the YOLO backend (`PoseDetectionSettings.useYOLO`), whose positions come
    /// from `worldJointPositions(fromPixelJoints:...)` rather than Vision's rootRelative/
    /// cameraOriginMatrix shape. The `poseSample`-based overload is now just this function fed
    /// `worldJointPositions(from: poseSample, ...)`'s output — behavior for every existing
    /// Vision caller is completely unchanged.
    static func classifyGripsAndFeet(
        worldPositions: [BodyJointName: SIMD3<Float>],
        handSample: HandPoseSample?,
        handCameraTransform: simd_float4x4?,
        cameraTransform: simd_float4x4,
        wallReference: ARSessionManager.WallTextureReference?
    ) -> (leftHand: GripClassification?, rightHand: GripClassification?, leftFoot: FootClassification?, rightFoot: FootClassification?) {
        let wallNormal = wallReference.flatMap { wallPlane(from: $0)?.normal }

        func handWorldJoints(_ cameraSpace: [HandJointName: SIMD3<Float>]) -> [HandJointName: SIMD3<Float>] {
            guard !cameraSpace.isEmpty else { return [:] }
            let transform = handCameraTransform ?? cameraTransform
            var out: [HandJointName: SIMD3<Float>] = [:]
            for (joint, cs) in cameraSpace {
                out[joint] = BodyPose3DExtractor.worldPosition(cameraSpace: cs, cameraTransform: transform)
            }
            return out
        }

        var leftHand: GripClassification?
        var rightHand: GripClassification?
        if let handSample {
            if let leftWrist = worldPositions[.leftWrist] {
                let forearm = worldPositions[.leftElbow].map { leftWrist - $0 }
                leftHand = GripClassifier.classifyHand(joints: handWorldJoints(handSample.leftHandJoints), wristWorld: leftWrist, forearmDirection: forearm, wallNormal: wallNormal)
            }
            if let rightWrist = worldPositions[.rightWrist] {
                let forearm = worldPositions[.rightElbow].map { rightWrist - $0 }
                rightHand = GripClassifier.classifyHand(joints: handWorldJoints(handSample.rightHandJoints), wristWorld: rightWrist, forearmDirection: forearm, wallNormal: wallNormal)
            }
        }

        var leftFoot: FootClassification?
        var rightFoot: FootClassification?
        if let leftAnkle = worldPositions[.leftAnkle] {
            let shin = worldPositions[.leftKnee].map { leftAnkle - $0 }
            leftFoot = GripClassifier.classifyFoot(ankleWorld: leftAnkle, hipWorld: worldPositions[.leftHip], shinDirection: shin, wallNormal: wallNormal)
        }
        if let rightAnkle = worldPositions[.rightAnkle] {
            let shin = worldPositions[.rightKnee].map { rightAnkle - $0 }
            rightFoot = GripClassifier.classifyFoot(ankleWorld: rightAnkle, hipWorld: worldPositions[.rightHip], shinDirection: shin, wallNormal: wallNormal)
        }

        return (leftHand, rightHand, leftFoot, rightFoot)
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
        leftGrip: GripClassification? = nil,
        rightGrip: GripClassification? = nil,
        leftFoot: FootClassification? = nil,
        rightFoot: FootClassification? = nil,
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
        /// partly buried inside the (visually larger) mannequin capsules. Hand/foot presets still
        /// render, since those attach at the wrist/ankle rather than needing to be tapped directly.
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
        // approximation — capsule radii are fixed anatomical guesses, NOT measured from this
        // specific climber (Step 2 calibration's segment LENGTHS already flow into joint spacing;
        // there's no equivalent measured girth/thickness to draw on). Skipped in pose-editing mode
        // — see `hideMannequinBody`'s doc comment.
        if !hideMannequinBody {
            for bone in skeletonBones {
                guard let a = worldPositions[bone.from], let b = worldPositions[bone.to] else { continue }
                if let capsule = capsuleBetween(a, b, radius: mannequinRadius(for: bone), material: mannequinMaterial) {
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

        // Hand/finger and foot/toe detail: classify-then-snap-to-preset instead of raw depth
        // reconstruction — see `GripClassifier`'s doc comment for the full reasoning (LiDAR's
        // ~1-3cm accuracy is close to finger/edge scale, and a gripping hand or wedged foot is
        // close to worst-case occlusion). `worldPositions` above already has the real, reliably
        // grounded wrist/ankle anchor points — only the SHAPE attached there is a preset, not the
        // anchor point itself. A nil-or-low-confidence classification renders an honest
        // "uncertain" marker instead of a named preset — see `handAttachmentEntity`.
        let wallNormal = wallReference.flatMap { wallPlane(from: $0)?.normal }
        if let leftWrist = worldPositions[.leftWrist] {
            let forearm = worldPositions[.leftElbow].map { leftWrist - $0 }
            root.addChild(handAttachmentEntity(classification: leftGrip, wristWorld: leftWrist, forearmDirection: forearm, wallNormal: wallNormal))
        }
        if let rightWrist = worldPositions[.rightWrist] {
            let forearm = worldPositions[.rightElbow].map { rightWrist - $0 }
            root.addChild(handAttachmentEntity(classification: rightGrip, wristWorld: rightWrist, forearmDirection: forearm, wallNormal: wallNormal))
        }
        if let leftAnkle = worldPositions[.leftAnkle] {
            let shin = worldPositions[.leftKnee].map { leftAnkle - $0 }
            root.addChild(footAttachmentEntity(classification: leftFoot, ankleWorld: leftAnkle, shinDirection: shin, wallNormal: wallNormal))
        }
        if let rightAnkle = worldPositions[.rightAnkle] {
            let shin = worldPositions[.rightKnee].map { rightAnkle - $0 }
            root.addChild(footAttachmentEntity(classification: rightFoot, ankleWorld: rightAnkle, shinDirection: shin, wallNormal: wallNormal))
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

    /// Attaches either a classified preset grip pose or an honest "uncertain" marker at a wrist
    /// position — see `GripClassifier`'s doc comment for why raw finger reconstruction isn't
    /// attempted. A nil classification (couldn't even attempt one, e.g. near-zero hand landmarks
    /// detected on a fully occluded grip) is treated identically to a low-confidence one: both
    /// show the same neutral marker rather than a guessed label, per the feature's required
    /// fallback behavior ("a visible not-confident beats a silently/confidently wrong answer").
    private static func handAttachmentEntity(
        classification: GripClassification?,
        wristWorld: SIMD3<Float>,
        forearmDirection: SIMD3<Float>?,
        wallNormal: SIMD3<Float>?
    ) -> Entity {
        guard let classification, classification.confidence >= GripClassifier.confidenceThreshold else {
            return uncertainMarkerEntity(at: wristWorld)
        }
        let layout = PresetPoseLibrary.handJointLayout(for: classification.type)
        let orientation = presetOrientation(primaryDirection: forearmDirection, secondaryFacingReference: wallNormal.map { -$0 })
        let presetJointMaterial = UnlitMaterial(color: .systemTeal)
        let presetBoneMaterial = UnlitMaterial(color: UIColor.systemTeal.withAlphaComponent(0.8))

        let root = Entity()
        var worldJoints: [HandJointName: SIMD3<Float>] = [:]
        for (joint, local) in layout {
            worldJoints[joint] = wristWorld + orientation.act(local)
        }
        for (joint, position) in worldJoints {
            let sphere = ModelEntity(mesh: .generateSphere(radius: 0.007), materials: [presetJointMaterial])
            sphere.position = position
            sphere.name = "presetHand.\(joint.rawValue)"
            root.addChild(sphere)
        }
        for bone in handBones {
            guard let a = worldJoints[bone.from], let b = worldJoints[bone.to] else { continue }
            if let boneEntity = cylinderBetween(a, b, radius: 0.005, material: presetBoneMaterial) {
                root.addChild(boneEntity)
            }
        }
        return root
    }

    /// Same idea as `handAttachmentEntity`, for a schematic climbing-shoe box at an ankle
    /// position instead of a hand joint layout.
    private static func footAttachmentEntity(
        classification: FootClassification?,
        ankleWorld: SIMD3<Float>,
        shinDirection: SIMD3<Float>?,
        wallNormal: SIMD3<Float>?
    ) -> Entity {
        guard let classification, classification.confidence >= GripClassifier.confidenceThreshold else {
            return uncertainMarkerEntity(at: ankleWorld)
        }
        let shape = PresetPoseLibrary.footShape(for: classification.type)
        let orientation = presetOrientation(primaryDirection: shinDirection, secondaryFacingReference: wallNormal.map { -$0 })
        var material = SimpleMaterial(color: UIColor.systemTeal.withAlphaComponent(0.85), roughness: 0.6, isMetallic: false)
        material.faceCulling = .none

        let entity = ModelEntity(mesh: .generateBox(size: shape.boxSize), materials: [material])
        entity.position = ankleWorld + orientation.act(shape.localOffset)
        entity.orientation = orientation * shape.localRotation
        return entity
    }

    /// Neutral "we don't have a confident answer" marker — a small translucent gray sphere plus a
    /// floating 3D "?" — shown instead of a named preset whenever classification confidence is
    /// too low. `MeshResource.generateText` is a real, non-throwing RealityKit API (iOS 13+); the
    /// font "size" is interpreted as roughly the text height in METERS, not points, which is why
    /// 0.03 (3cm) is used here rather than a normal UIFont point size — UNVERIFIED ON DEVICE, if
    /// the "?" comes out comically large/tiny that unit assumption is the first thing to check.
    private static func uncertainMarkerEntity(at position: SIMD3<Float>) -> Entity {
        let root = Entity()
        var sphereMaterial = SimpleMaterial(color: UIColor.systemGray.withAlphaComponent(0.55), roughness: 0.8, isMetallic: false)
        sphereMaterial.faceCulling = .none
        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.028), materials: [sphereMaterial])
        sphere.position = position
        root.addChild(sphere)

        let textMesh = MeshResource.generateText(
            "?",
            extrusionDepth: 0.002,
            font: .systemFont(ofSize: 0.03)
        )
        let textEntity = ModelEntity(mesh: textMesh, materials: [UnlitMaterial(color: .white)])
        textEntity.position = position + SIMD3<Float>(-0.008, 0.04, 0)
        root.addChild(textEntity)
        return root
    }

    /// Coarse local->world rotation for attaching a preset shape: local +Y maps onto
    /// `primaryDirection` (forearm continuing into the hand, or shin continuing past the ankle),
    /// using the same up-onto-direction recipe as `cylinderBetween`/`capsuleBetween` above. The
    /// remaining twist around that axis points the preset's local +X axis as close as possible
    /// toward `secondaryFacingReference` (e.g. "into the wall") when available. Deliberately
    /// coarse, per the feature brief: "even an approximate [direction] is enough — do not attempt
    /// precise rotation matching."
    private static func presetOrientation(primaryDirection: SIMD3<Float>?, secondaryFacingReference: SIMD3<Float>?) -> simd_quatf {
        guard let primaryDirection, simd_length(primaryDirection) > 0.0001 else {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }
        let direction = normalize(primaryDirection)
        let localUp = SIMD3<Float>(0, 1, 0)
        var base = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let dot = simd_dot(localUp, direction)
        if dot < -0.9999 {
            base = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        } else if dot < 0.9999 {
            let axis = normalize(simd_cross(localUp, direction))
            base = simd_quatf(angle: acos(dot), axis: axis)
        }
        guard let secondaryFacingReference, simd_length(secondaryFacingReference) > 0.0001 else { return base }

        // Twist around `direction` so the preset's local +X points as close as possible toward
        // `secondaryFacingReference`, projected into the plane perpendicular to `direction`.
        let currentLocalX = base.act(SIMD3<Float>(1, 0, 0))
        let target = secondaryFacingReference - direction * simd_dot(secondaryFacingReference, direction)
        guard simd_length(target) > 0.0001 else { return base }
        let normalizedTarget = normalize(target)
        let projectedCurrent = normalize(currentLocalX - direction * simd_dot(currentLocalX, direction))
        let twistDot = min(max(simd_dot(projectedCurrent, normalizedTarget), -1), 1)
        let twistSign: Float = simd_dot(simd_cross(projectedCurrent, normalizedTarget), direction) < 0 ? -1 : 1
        let twist = simd_quatf(angle: acos(twistDot) * twistSign, axis: direction)
        return twist * base
    }

    /// Mannequin limb segment: same rotate-a-cylinder-onto-a-direction trick as `cylinderBetween`
    /// (in fact identical geometry — `MeshResource.generateCapsule` doesn't exist on this
    /// RealityKit version, confirmed by a real build error, so this is a plain cylinder). The
    /// rounded-off look comes from `skeletonEntity` also dropping a sphere at every joint (see
    /// `mannequinJointRadius`) sized to match the thickest connected limb, which covers the flat
    /// cylinder end caps instead of leaving visible seams at the joints.
    private static func capsuleBetween(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: Float, material: Material) -> Entity? {
        let distance = simd_distance(a, b)
        guard distance > 0.001 else { return nil }
        let mesh = MeshResource.generateCylinder(height: distance, radius: radius)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = (a + b) / 2

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

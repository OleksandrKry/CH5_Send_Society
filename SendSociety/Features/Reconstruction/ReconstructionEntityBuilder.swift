import RealityKit
import ARKit
import simd
import UIKit

/// Builds RealityKit entities for the Step 4 static reconstruction: the previously-scanned wall
/// mesh, and a single frame's body-pose skeleton, both placed in the SAME ARKit world coordinate
/// space they were captured in (both come from the one shared ARSession — see ARSessionManager).
enum ReconstructionEntityBuilder {

    // MARK: - Wall mesh

    static func wallEntity(from anchors: [ARMeshAnchor]) -> Entity {
        let root = Entity()
        var material = UnlitMaterial(color: UIColor.cyan.withAlphaComponent(0.35))
        material.faceCulling = .none

        for anchor in anchors {
            guard let mesh = try? meshResource(from: anchor.geometry) else { continue }
            let modelEntity = ModelEntity(mesh: mesh, materials: [material])
            modelEntity.transform.matrix = anchor.transform
            root.addChild(modelEntity)
        }
        DebugLog.reconstruction.info("Wall entity built from \(anchors.count, privacy: .public) mesh anchors")
        return root
    }

    private static func meshResource(from geometry: ARMeshGeometry) throws -> MeshResource {
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
        return try MeshResource.generate(from: [descriptor])
    }

    // MARK: - Skeleton

    static func skeletonEntity(from sample: BodyPoseSample, cameraTransform: simd_float4x4) -> Entity {
        let root = Entity()
        let jointMaterial = UnlitMaterial(color: .systemYellow)
        let boneMaterial = UnlitMaterial(color: .systemRed)

        var worldPositions: [BodyJointName: SIMD3<Float>] = [:]
        for (joint, local) in sample.rootRelativePositions {
            worldPositions[joint] = BodyPose3DExtractor.worldPosition(
                rootRelative: local,
                cameraOriginMatrix: sample.cameraOriginMatrix,
                cameraTransform: cameraTransform
            )
        }

        for (joint, position) in worldPositions {
            let sphere = ModelEntity(mesh: .generateSphere(radius: 0.02), materials: [jointMaterial])
            sphere.position = position
            sphere.name = "joint.\(joint.rawValue)"
            root.addChild(sphere)
        }

        for bone in skeletonBones {
            guard let a = worldPositions[bone.from], let b = worldPositions[bone.to] else { continue }
            if let boneEntity = cylinderBetween(a, b, radius: 0.01, material: boneMaterial) {
                root.addChild(boneEntity)
            }
        }

        DebugLog.reconstruction.info("Skeleton entity built with \(worldPositions.count, privacy: .public)/17 joints resolved")
        return root
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

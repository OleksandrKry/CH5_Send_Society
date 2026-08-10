import simd

/// Pure "drag a 3D point via a 2D touch" math for `ReconstructionView`'s Edit Pose gesture — pulled
/// out of `ReconstructionSceneView.Coordinator.updateJointDrag` so the actual unprojection algorithm
/// lives in this module (plain vector math, no UIKit/RealityKit types), not embedded in a UIKit
/// gesture-handler method. The Coordinator still owns getting a screen-space ray and camera forward
/// vector from `ARView` — this just does the geometry once it has them.
enum JointDragProjector {
    /// Unprojects a screen-space ray onto a plane through `planePoint`, facing the camera (i.e. the
    /// joint drags across a fixed depth-from-camera plane rather than trying to also infer depth
    /// from a single 2D touch, which isn't possible without a second input). This is the standard
    /// technique for "drag a 3D point via a 2D touch" — the same idea behind most simple AR
    /// object-manipulation tools.
    ///
    /// Returns nil when the ray is (near) parallel to the plane — can't meaningfully intersect — or
    /// when the intersection lands behind the ray's origin (e.g. behind the camera). Both mean
    /// "ignore this touch frame," not an error; the caller should just leave the joint where it was.
    static func project(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        planePoint: SIMD3<Float>,
        planeNormal: SIMD3<Float>
    ) -> SIMD3<Float>? {
        let denominator = simd_dot(rayDirection, planeNormal)
        guard abs(denominator) > 0.0001 else { return nil }
        let t = simd_dot(planePoint - rayOrigin, planeNormal) / denominator
        guard t > 0 else { return nil }
        return rayOrigin + rayDirection * t
    }
}

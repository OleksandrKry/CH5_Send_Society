import ARKit

enum LiDARSupport {
    /// True only on devices with a LiDAR scanner capable of ARKit scene reconstruction.
    /// Checked once at launch — the app must fail gracefully (not silently misbehave) on
    /// unsupported devices.
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }
}

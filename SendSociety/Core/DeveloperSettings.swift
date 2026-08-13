import Foundation

/// Tiny UserDefaults-backed switches for on-device debugging — deliberately NOT a real settings
/// screen (this app has none), just the smallest possible persisted flag so a developer's choice
/// (e.g. "show the raw LiDAR mesh") survives leaving and reopening a screen, and even relaunching
/// the app, instead of resetting every time. Add more flags here the same way if a similar need
/// comes up rather than inventing a second pattern.
enum DeveloperSettings {
    private static let showMeshKey = "com.sendsociety.dev.showMesh"

    /// Whether `ARMeshSceneView` should render the built-in scene-reconstruction wireframe.
    /// Defaults to `false` (unset key reads as `false` via `UserDefaults.bool(forKey:)`) — an
    /// ordinary coach should never see raw mesh geometry; see `ARMeshSceneView.showMesh`'s doc
    /// comment for why. A developer (or a curious coach) can flip this on via `MeshToggleButton`
    /// on Step 1's wall-scan screen or the record screen — one shared flag, so the choice is
    /// consistent across both instead of two independent toggles that could disagree.
    static var showMesh: Bool {
        get { UserDefaults.standard.bool(forKey: showMeshKey) }
        set { UserDefaults.standard.set(newValue, forKey: showMeshKey) }
    }
}

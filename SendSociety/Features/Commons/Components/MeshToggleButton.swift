import SwiftUI

/// Small, low-prominence button that toggles `ARMeshSceneView`'s live LiDAR mesh wireframe on/off
/// — OFF by default for an ordinary coach (see `ARMeshSceneView.showMesh`'s doc comment), but
/// reachable in one tap for a developer checking how the scan mesh is actually holding up against
/// a real wall. Backed by `DeveloperSettings.showMesh` so the choice persists across screens
/// (Step 1's wall-scan screen and the record screen both use this same button/flag) and across
/// relaunches.
struct MeshToggleButton: View {
    @Binding var showMesh: Bool

    var body: some View {
        Button {
            showMesh.toggle()
            DeveloperSettings.showMesh = showMesh
        } label: {
            Image(systemName: showMesh ? "cube.transparent.fill" : "cube.transparent")
                .font(.footnote)
                .foregroundStyle(showMesh ? Color.accentColor : .secondary)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(showMesh ? "Hide LiDAR mesh" : "Show LiDAR mesh")
    }
}

#Preview {
    MeshToggleButton(showMesh: .constant(false))
}

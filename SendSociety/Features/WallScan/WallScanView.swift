import SwiftUI
import ARKit

/// Step 1 — Scan the Wall.
struct WallScanView: View {
    @ObservedObject var arManager: ARSessionManager
    let onDone: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            ARMeshSceneView(session: arManager.session)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                instructionBanner
                trackingCue
                Spacer()
                coverageBadge
                doneButton
            }
            .padding()
        }
        .onAppear {
            arManager.startIfNeeded()
            DebugLog.wallScan.info("Step 1 wall scan started")
        }
    }

    private var instructionBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Step 1 — Scan the Wall").font(.headline)
            Text("Slowly pan across the climbing wall. Keep the wall in frame and avoid fast motion until coverage looks solid.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var trackingCue: some View {
        if let message = arManager.trackingQuality.message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.9), in: Capsule())
                .foregroundStyle(.white)
        }
    }

    private var coverageBadge: some View {
        HStack {
            Image(systemName: "cube.transparent")
            Text("Mesh coverage: \(arManager.meshAnchors.count) anchors · \(arManager.estimatedTriangleCount) triangles")
                .font(.footnote.monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var doneButton: some View {
        Button {
            let anchorCount = arManager.meshAnchors.count
            let triangleCount = arManager.estimatedTriangleCount
            DebugLog.wallScan.info("Wall scan marked done — \(anchorCount, privacy: .public) mesh anchors, \(triangleCount, privacy: .public) triangles")
            if arManager.meshAnchors.isEmpty {
                DebugLog.wallScan.error("Wall scan finished with ZERO mesh anchors — success criterion 1 has failed for this attempt")
            }
            onDone()
        } label: {
            Text("Done Scanning")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
    }
}

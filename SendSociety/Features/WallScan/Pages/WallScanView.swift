import SwiftUI
import ARKit

/// Step 1 — Scan the Wall.
struct WallScanView: View {
    @ObservedObject var arManager: ARSessionManager
    let onDone: () -> Void

    /// Live "would Step 4's wall have holes right now" cue — see
    /// `ARSessionManager.depthConfidenceRatio`. Sampled on a timer (not every frame) since
    /// scanning the whole depth grid pixel-by-pixel isn't free.
    @State private var depthQuality: Double?
    @State private var confidenceGrid: [[Double]]?
    @State private var qualityTimer: Timer?

    var body: some View {
        ZStack(alignment: .top) {
            ARMeshSceneView(session: arManager.session)
                .ignoresSafeArea()

            coverageHeatmapOverlay
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 12) {
                instructionBanner
                trackingCue
                Spacer()
                depthQualityBadge
                coverageBadge
                doneButton
            }
            .padding()
        }
        .onAppear {
            arManager.startIfNeeded()
            DebugLog.wallScan.info("Step 1 wall scan started")
            qualityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                let frame = arManager.latestFrame
                depthQuality = ARSessionManager.depthConfidenceRatio(for: frame)
                if let rawGrid = ARSessionManager.depthConfidenceGrid(for: frame, columns: 6, rows: 8) {
                    confidenceGrid = ARSessionManager.rotatedForCurrentOrientation(rawGrid)
                } else {
                    confidenceGrid = nil
                }
            }
        }
        .onDisappear {
            qualityTimer?.invalidate()
            qualityTimer = nil
        }
    }

    /// Rough "scan this area more" cue: a red tint over regions where the depth sensor currently
    /// has low confidence, fading out as confidence improves — same spirit as the diagonal-stripe
    /// overlays in Apple's own room/object scanning UIs, though this is a live per-frame
    /// approximation, not persistent whole-wall coverage memory (see
    /// `ARSessionManager.depthConfidenceGrid`'s doc comment for the distinction). Distorts to fill
    /// the screen rather than matching the camera's exact crop/FOV — an approximation, not a
    /// pixel-perfect overlay.
    @ViewBuilder
    private var coverageHeatmapOverlay: some View {
        if let confidenceGrid, !confidenceGrid.isEmpty {
            VStack(spacing: 0) {
                ForEach(0..<confidenceGrid.count, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<confidenceGrid[row].count, id: \.self) { col in
                            Rectangle()
                                .fill(Color.red)
                                .opacity(max(0, 0.5 * (1 - confidenceGrid[row][col])))
                        }
                    }
                }
            }
        }
    }

    /// Text guidance so the coach knows whether NOW (the moment they'd tap Done Scanning) is a
    /// good time to finish — Step 4's wall bump detail comes from a single frame's depth grid, so
    /// holes in that one frame become holes in the final 3D wall. Doesn't block "Done Scanning" —
    /// just tells the coach what to expect.
    @ViewBuilder
    private var depthQualityBadge: some View {
        let ratio = depthQuality ?? 0
        let percent = Int((depthQuality ?? 0) * 100)
        HStack {
            Image(systemName: depthQuality == nil ? "questionmark.circle" : "circle.fill")
                .font(.caption2)
                .foregroundStyle(depthQuality == nil ? .secondary : qualityColor(ratio))
            Group {
                if depthQuality == nil {
                    Text("Depth quality: unavailable")
                } else if ratio < 0.5 {
                    Text("Depth quality: Low (\(percent)%) — move closer, scan slower, avoid shiny/dark holds")
                } else if ratio < 0.8 {
                    Text("Depth quality: Fair (\(percent)%) — keep scanning the whole wall before Done")
                } else {
                    Text("Depth quality: Good (\(percent)%) — ready to tap Done Scanning")
                }
            }
            .font(.footnote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func qualityColor(_ ratio: Double) -> Color {
        if ratio < 0.5 { return .red }
        if ratio < 0.8 { return .orange }
        return .green
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
            // Grab a color reference frame here (coach should be holding a good overview shot
            // of the wall right before tapping Done) so Step 4 can texture the mesh with real
            // captured color instead of a flat placeholder.
            arManager.captureWallTextureReference()
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

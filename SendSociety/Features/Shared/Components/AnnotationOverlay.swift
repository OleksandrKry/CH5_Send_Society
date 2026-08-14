import SwiftUI

/// Simple OnForm-style screen-space markup for the Step 4 3D view — pen, straight line, and angle
/// (two connected segments sharing a vertex, with the angle between them shown as text, useful
/// for calling out e.g. an elbow or hip bend directly on the rendered pose).
///
/// Deliberately 2D/screen-space, drawn ON TOP of the 3D view rather than attached to the 3D scene
/// — the same way OnForm and similar climbing/gymnastics video-analysis apps draw on a paused
/// frame. That keeps this simple (no 3D raycasting/anchoring needed) and matches what "annotation"
/// means in the reference app the coach is used to.
///
/// `AnnotationTool`/`AnnotationStroke` (the tool enum and the persisted stroke data) live in
/// `Core/Models.swift`, not here — see that file's doc comment for why: `AnnotationStroke` is
/// saved as part of a `RecordingSession`, so the persistence layer needs it without importing this
/// UI file. Everything actually UI-shaped (the drawing surface, the toolbar, and the shared
/// `ObservableObject` state) stays in this file.

/// Shared between `AnnotationOverlay` (the drawing surface) and `AnnotationToolbar` (tool
/// picker/clear/undo) — both need to read and mutate the same strokes/tool selection, so
/// `ReconstructionView` owns one instance and hands it to both.
final class AnnotationState: ObservableObject {
    @Published var strokes: [AnnotationStroke] = []
    @Published var tool: AnnotationTool = .pen

    /// The angle tool is a 2-step gesture (draw the first segment, then a second segment from the
    /// same vertex) — these hold the first segment while waiting for the second. Reset whenever
    /// the tool is switched, so a half-finished angle from before a tool change can't silently
    /// complete with a stale vertex.
    fileprivate var pendingAngleVertex: CGPoint?
    fileprivate var pendingAngleFirstEnd: CGPoint?

    func clear() {
        strokes.removeAll()
        pendingAngleVertex = nil
        pendingAngleFirstEnd = nil
    }

    func undo() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
    }

    func selectTool(_ newTool: AnnotationTool) {
        tool = newTool
        pendingAngleVertex = nil
        pendingAngleFirstEnd = nil
    }

    /// Swaps in a different set of strokes wholesale — used when video playback moves to a
    /// different timestamp bucket and that moment has its own saved annotations (or none). Not
    /// the same as `clear()`: this REPLACES the strokes with someone else's (possibly non-empty)
    /// set, rather than emptying the current one.
    func load(strokes: [AnnotationStroke]) {
        self.strokes = strokes
        pendingAngleVertex = nil
        pendingAngleFirstEnd = nil
    }
}

struct AnnotationOverlay: View {
    @ObservedObject var state: AnnotationState
    /// True (the default) draws the strokes AND captures drag touches to draw new ones — this is
    /// the original, only behavior this view used to have, still what both `ReconstructionView`
    /// call sites want for their interactive Annotate mode.
    ///
    /// False renders the exact same `canvasContent` but attaches neither `.contentShape` nor the
    /// drawing `.gesture` — a pure, read-only "show whatever's already saved" mode, so a caller can
    /// overlay it on a paused, non-annotate-mode video (see `PlaybackView`/`SessionReviewView`'s
    /// auto-preview) WITHOUT stealing touches that should still reach the play/pause/scrub controls
    /// underneath or beside it.
    var isInteractive: Bool = true
    @State private var liveStroke: [CGPoint] = []
    @State private var liveAngleEnd: CGPoint?

    var body: some View {
        if isInteractive {
            canvasContent
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged(handleChanged)
                        .onEnded(handleEnded)
                )
        } else {
            canvasContent
                .allowsHitTesting(false)
        }
    }

    private var canvasContent: some View {
        Canvas { context, _ in
            for stroke in state.strokes {
                draw(stroke: stroke, in: &context)
            }
            if !liveStroke.isEmpty {
                draw(stroke: AnnotationStroke(tool: state.tool, points: liveStroke), in: &context, isPreview: true)
            }
            // The angle tool's first segment stays visible (solid, not preview-faded) while
            // waiting for the second drag, so it's clear the tool is mid-gesture rather than done.
            if let vertex = state.pendingAngleVertex, let firstEnd = state.pendingAngleFirstEnd {
                var path = Path()
                path.move(to: firstEnd)
                path.addLine(to: vertex)
                context.stroke(path, with: .color(.yellow), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                if let liveAngleEnd {
                    draw(stroke: AnnotationStroke(tool: .angle, points: [vertex, firstEnd, liveAngleEnd]), in: &context, isPreview: true)
                }
            }
        }
    }

    private func handleChanged(_ value: DragGesture.Value) {
        switch state.tool {
        case .pen:
            liveStroke.append(value.location)
        case .line:
            liveStroke = [value.startLocation, value.location]
        case .angle:
            if state.pendingAngleVertex != nil {
                liveAngleEnd = value.location
            } else {
                liveStroke = [value.startLocation, value.location]
            }
        }
    }

    private func handleEnded(_ value: DragGesture.Value) {
        switch state.tool {
        case .pen:
            if liveStroke.count > 1 {
                state.strokes.append(AnnotationStroke(tool: .pen, points: liveStroke))
            }
            liveStroke = []
        case .line:
            state.strokes.append(AnnotationStroke(tool: .line, points: [value.startLocation, value.location]))
            liveStroke = []
        case .angle:
            if let vertex = state.pendingAngleVertex, let firstEnd = state.pendingAngleFirstEnd {
                // Second segment — the vertex is whatever the FIRST drag started at, not
                // wherever this second drag happens to start, so the coach doesn't need
                // pixel-perfect precision to "reconnect" at the shared point.
                state.strokes.append(AnnotationStroke(tool: .angle, points: [vertex, firstEnd, value.location]))
                state.pendingAngleVertex = nil
                state.pendingAngleFirstEnd = nil
                liveAngleEnd = nil
            } else {
                state.pendingAngleVertex = value.startLocation
                state.pendingAngleFirstEnd = value.location
                liveStroke = []
            }
        }
    }

    private func draw(stroke: AnnotationStroke, in context: inout GraphicsContext, isPreview: Bool = false) {
        let color: Color = isPreview ? Color.yellow.opacity(0.7) : .yellow
        switch stroke.tool {
        case .pen:
            guard stroke.points.count > 1 else { return }
            var path = Path()
            path.move(to: stroke.points[0])
            for point in stroke.points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        case .line:
            guard stroke.points.count >= 2 else { return }
            var path = Path()
            path.move(to: stroke.points[0])
            path.addLine(to: stroke.points[1])
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        case .angle:
            guard stroke.points.count >= 2 else { return }
            let vertex = stroke.points[0]
            let firstEnd = stroke.points[1]
            var path = Path()
            path.move(to: firstEnd)
            path.addLine(to: vertex)
            if stroke.points.count >= 3 {
                path.addLine(to: stroke.points[2])
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            if stroke.points.count >= 3 {
                let degrees = angleDegrees(vertex: vertex, a: firstEnd, b: stroke.points[2])
                let label = String(format: "%.0f°", degrees)
                context.draw(Text(label).font(.headline.bold()).foregroundColor(.yellow), at: CGPoint(x: vertex.x + 14, y: vertex.y - 14))
            }
        }
    }

    private func angleDegrees(vertex: CGPoint, a: CGPoint, b: CGPoint) -> Double {
        let v1 = CGVector(dx: a.x - vertex.x, dy: a.y - vertex.y)
        let v2 = CGVector(dx: b.x - vertex.x, dy: b.y - vertex.y)
        let mag1 = sqrt(v1.dx * v1.dx + v1.dy * v1.dy)
        let mag2 = sqrt(v2.dx * v2.dx + v2.dy * v2.dy)
        guard mag1 > 0.0001, mag2 > 0.0001 else { return 0 }
        let cosTheta = min(max((v1.dx * v2.dx + v1.dy * v2.dy) / (mag1 * mag2), -1), 1)
        return acos(cosTheta) * 180 / .pi
    }
}

/// Tool picker + undo/clear, shown as a floating capsule at the bottom of the screen while
/// annotate mode is active.
struct AnnotationToolbar: View {
    @ObservedObject var state: AnnotationState

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                Button {
                    state.selectTool(tool)
                } label: {
                    Image(systemName: tool.systemImage)
                        .frame(width: 20, height: 20)
                        .padding(10)
                        .background(state.tool == tool ? Color.accentColor : Color.black.opacity(0.35), in: Circle())
                        .foregroundStyle(.white)
                }
            }
            Divider().frame(height: 24)
            Button {
                state.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 20, height: 20)
                    .padding(10)
                    .background(Color.black.opacity(0.35), in: Circle())
                    .foregroundStyle(.white)
            }
            Button {
                state.clear()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 20, height: 20)
                    .padding(10)
                    .background(Color.black.opacity(0.35), in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

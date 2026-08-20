import SwiftUI

final class AnnotationState: ObservableObject {
    @Published var strokes: [AnnotationStrokeModel] = []
    @Published var tool: AnnotationTool = .pen

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

    func load(strokes: [AnnotationStrokeModel]) {
        self.strokes = strokes
        pendingAngleVertex = nil
        pendingAngleFirstEnd = nil
    }
}

struct AnnotationComponent: View {
    @ObservedObject var annotationState: AnnotationState
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
            for stroke in annotationState.strokes {
                draw(stroke: stroke, in: &context)
            }
            if !liveStroke.isEmpty {
                draw(stroke: AnnotationStrokeModel(tool: annotationState.tool, points: liveStroke), in: &context, isPreview: true)
            }
            // The angle tool's first segment stays visible (solid, not preview-faded) while
            // waiting for the second drag, so it's clear the tool is mid-gesture rather than done.
            if let vertex = annotationState.pendingAngleVertex, let firstEnd = annotationState.pendingAngleFirstEnd {
                var path = Path()
                path.move(to: firstEnd)
                path.addLine(to: vertex)
                context.stroke(path, with: .color(AppColor.AnnotateGreen), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                if let liveAngleEnd {
                    draw(stroke: AnnotationStrokeModel(tool: .angle, points: [vertex, firstEnd, liveAngleEnd]), in: &context, isPreview: true)
                }
            }
        }
    }

    private func handleChanged(_ value: DragGesture.Value) {
        switch annotationState.tool {
        case .pen:
            liveStroke.append(value.location)
        case .line, .arrow, .circle:
            liveStroke = [value.startLocation, value.location]
        case .angle:
            if annotationState.pendingAngleVertex != nil {
                liveAngleEnd = value.location
            } else {
                liveStroke = [value.startLocation, value.location]
            }
        case .text:
            break
        }
        
    }

    private func handleEnded(_ value: DragGesture.Value) {
        switch annotationState.tool {
        case .pen:
            if liveStroke.count > 1 {
                annotationState.strokes.append(AnnotationStrokeModel(tool: .pen, points: liveStroke))
            }
            liveStroke = []
        case .line, .arrow, .circle:
            annotationState.strokes.append(AnnotationStrokeModel(tool: annotationState.tool, points: [value.startLocation, value.location]))
            liveStroke = []
        case .angle:
            if let vertex = annotationState.pendingAngleVertex, let firstEnd = annotationState.pendingAngleFirstEnd {
                // Second segment — the vertex is whatever the FIRST drag started at, not
                // wherever this second drag happens to start, so the coach doesn't need
                // pixel-perfect precision to "reconnect" at the shared point.
                annotationState.strokes.append(AnnotationStrokeModel(tool: .angle, points: [vertex, firstEnd, value.location]))
                annotationState.pendingAngleVertex = nil
                annotationState.pendingAngleFirstEnd = nil
                liveAngleEnd = nil
            } else {
                annotationState.pendingAngleVertex = value.startLocation
                annotationState.pendingAngleFirstEnd = value.location
                liveStroke = []
            }
        case .text:
            break
        }
    }

    private func draw(stroke: AnnotationStrokeModel, in context: inout GraphicsContext, isPreview: Bool = false) {
        let color: Color = isPreview ? Color.yellow.opacity(0.7) : .yellow
        switch stroke.tool {
        case .pen:
            guard stroke.points.count > 1 else { return }
            var path = Path()
            path.move(to: stroke.points[0])
            for point in stroke.points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(AppColor.AnnotateRed), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        case .line:
            guard stroke.points.count >= 2 else { return }
            var path = Path()
            path.move(to: stroke.points[0])
            path.addLine(to: stroke.points[1])
            context.stroke(path, with: .color(AppColor.AnnotateRed), style: StrokeStyle(lineWidth: 3, lineCap: .round))
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
            context.stroke(path, with: .color(AppColor.AnnotateGreen), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            if stroke.points.count >= 3 {
                let degrees = angleDegrees(vertex: vertex, a: firstEnd, b: stroke.points[2])
                let label = String(format: "%.0f°", degrees)
                context.draw(Text(label).font(.headline.bold()).foregroundColor(AppColor.AnnotateGreen), at: CGPoint(x: vertex.x + 14, y: vertex.y - 14))
            }
        case .circle:
            guard stroke.points.count >= 2 else { return }
            let center = stroke.points[0]
            let edge = stroke.points[1]
            let radius = hypot(edge.x - center.x, edge.y - center.y)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(AppColor.AnnotateYellow), style: StrokeStyle(lineWidth: 3))
        case .arrow:
            guard stroke.points.count >= 2 else { return }
            let start = stroke.points[0]
            let end = stroke.points[1]
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(AppColor.AnnotateBlue), style: StrokeStyle(lineWidth: 3, lineCap: .round))

            let angle = atan2(end.y - start.y, end.x - start.x)
            let arrowLength: CGFloat = 14
            let arrowAngle: CGFloat = .pi / 7
            let left = CGPoint(x: end.x - arrowLength * cos(angle - arrowAngle), y: end.y - arrowLength * sin(angle - arrowAngle))
            let right = CGPoint(x: end.x - arrowLength * cos(angle + arrowAngle), y: end.y - arrowLength * sin(angle + arrowAngle))
            var head = Path()
            head.move(to: left)
            head.addLine(to: end)
            head.addLine(to: right)
            context.stroke(head, with: .color(AppColor.AnnotateBlue), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        case .text:
            break
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

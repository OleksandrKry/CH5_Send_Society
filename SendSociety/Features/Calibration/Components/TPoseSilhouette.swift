import SwiftUI

/// A simple stick-figure T-pose outline — arms straight out to the sides, legs shoulder-width
/// apart — for the climber to visually line their body up against before Step 2 starts capturing.
/// Purely a visual guide, drawn proportionally within whatever frame it's given; not tied to any
/// detected joint positions. Used only by `CalibrationView` — pulled into its own file since it's a
/// reusable rendering primitive, not page logic.
struct TPoseSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let centerX = rect.midX

        let headRadius = h * 0.06
        let headCenterY = rect.minY + headRadius * 1.2
        path.addEllipse(in: CGRect(x: centerX - headRadius, y: headCenterY - headRadius, width: headRadius * 2, height: headRadius * 2))

        let neckY = headCenterY + headRadius
        let hipY = rect.minY + h * 0.55
        let shoulderY = neckY + (hipY - neckY) * 0.12
        let footY = rect.minY + h * 0.98

        // Torso
        path.move(to: CGPoint(x: centerX, y: neckY))
        path.addLine(to: CGPoint(x: centerX, y: hipY))

        // Arms — the "T": straight out to the sides at shoulder height
        path.move(to: CGPoint(x: rect.minX + w * 0.04, y: shoulderY))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.04, y: shoulderY))

        // Legs — shoulder-width apart, down to the bottom of the guide
        path.move(to: CGPoint(x: centerX, y: hipY))
        path.addLine(to: CGPoint(x: centerX - w * 0.12, y: footY))
        path.move(to: CGPoint(x: centerX, y: hipY))
        path.addLine(to: CGPoint(x: centerX + w * 0.12, y: footY))

        return path
    }
}

import SwiftUI
import ARKit
import UIKit

/// Draws Vision's own detected 2D skeleton directly on top of a single video frame — lets a
/// coach sanity-check "does Vision actually see this climber's pose correctly here" BEFORE
/// spending time on the heavier Generate/Estimate 3D step, which builds on exactly this same
/// detection. See `SessionReviewView`'s "Preview Skeleton" toggle for where this is used.
///
/// ALIGNMENT STRATEGY: `image` and `points` are both in the RAW (unrotated) sensor frame's own
/// pixel space (`BodyPose3DExtractor.projected2DImagePoints`'s native output, same convention as
/// `VideoFrameExtractor`/`ARFrame.capturedImage`) — this view draws them together, in that same
/// raw coordinate space, as ONE combined layer, and only THEN rotates the whole combined layer
/// upright as a single unit. That ordering guarantees the skeleton can never drift out of
/// alignment with the image beneath it, even if the rotation direction below ever turns out to
/// be wrong for some orientation — the only possible failure mode is "the whole preview is
/// sideways/upside-down" (obvious, trivial one-line fix), never a subtle position mismatch.
///
/// The rotation angles used are the EXACT same ones `VideoRecorder.videoTransform(for:)` already
/// applies (and has been verified on-device against) to make this app's own recorded .mp4 files
/// display upright — reused here rather than re-deriving a new rotation from scratch.
struct SkeletonImageOverlayView: View {
    let cgImage: CGImage
    /// Raw pixel coordinates (`BodyPose3DExtractor.projected2DImagePoints`'s output) — empty
    /// means "frame extracted fine, but no person detected here," which is itself a useful,
    /// honest answer worth showing (the raw frame still renders, just with nothing drawn on it).
    let points: [BodyJointName: CGPoint]
    let deviceOrientation: UIDeviceOrientation

    private var rawSize: CGSize {
        CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
    }

    /// The raw sensor buffer is landscape-shaped hardware-wise regardless of how the phone is
    /// actually held — for the portrait cases, the 90°/-90° rotation below swaps which raw
    /// dimension reads as the displayed width vs. height. Mirrors `cameraOrientation(for:)`'s
    /// device-orientation grouping.
    private var rotatedSize: CGSize {
        switch deviceOrientation {
        case .landscapeLeft, .landscapeRight:
            return rawSize
        default:
            return CGSize(width: rawSize.height, height: rawSize.width)
        }
    }

    private var rotationAngle: Angle {
        switch deviceOrientation {
        case .portrait: return .radians(.pi / 2)
        case .portraitUpsideDown: return .radians(-.pi / 2)
        case .landscapeLeft: return .radians(.pi)
        case .landscapeRight: return .radians(0)
        default: return .radians(.pi / 2) // faceUp/faceDown/unknown — this app's primary orientation
        }
    }

    var body: some View {
        // `rawSize`/`rotatedSize` are in raw SENSOR PIXELS (e.g. ~1920x1440) — orders of
        // magnitude bigger than a phone screen's SwiftUI POINT coordinate space. Chaining a fixed
        // `.frame(width:height:)` straight into `.aspectRatio(...)` (an earlier version of this
        // view did exactly that) never actually shrinks it: a fixed frame reports that literal
        // huge size up to the parent regardless of what space was actually available, which was
        // overflowing this view WAY past the screen — pushing `SessionReviewView`'s controls
        // below it (including the very button that turns this preview back off) off-screen and
        // unreachable. `GeometryReader` here reads the space this view actually has to work with,
        // and the trailing `.frame(width: geometry.size...)` at the end pins the REPORTED size to
        // exactly that — `.scaleEffect` (visual-only, doesn't affect layout size) does the actual
        // shrinking of the oversized rotated content down to fit inside it.
        GeometryReader { geometry in
            let scale = safeScale(toFitIn: geometry.size)
            ZStack {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                Canvas { context, size in
                    // Scale factor from the raw image's native pixel dimensions to whatever size
                    // SwiftUI actually laid this Canvas out at — should be ~1.0 in practice (the
                    // enclosing `.frame` below pins both the Image and this Canvas to `rawSize`
                    // exactly), kept as an explicit computation rather than assumed for robustness.
                    let scaleX = size.width / rawSize.width
                    let scaleY = size.height / rawSize.height
                    func scaled(_ point: CGPoint) -> CGPoint {
                        CGPoint(x: point.x * scaleX, y: point.y * scaleY)
                    }
                    for bone in skeletonBones {
                        guard let from = points[bone.from], let to = points[bone.to] else { continue }
                        var path = Path()
                        path.move(to: scaled(from))
                        path.addLine(to: scaled(to))
                        context.stroke(path, with: .color(.green), lineWidth: 3)
                    }
                    for (_, point) in points {
                        let p = scaled(point)
                        let dotRect = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                        context.fill(Path(ellipseIn: dotRect), with: .color(.yellow))
                    }
                }
            }
            .frame(width: rawSize.width, height: rawSize.height)
            .rotationEffect(rotationAngle)
            .frame(width: rotatedSize.width, height: rotatedSize.height)
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    /// How much to shrink (or, for a tiny frame, grow) the post-rotation content by by so it fits
    /// entirely within `available`, preserving aspect ratio — `min` of the two axis ratios so
    /// neither dimension overflows. Guards against 0/NaN/infinite results (a momentarily
    /// zero-sized `GeometryReader` during layout, or a degenerate 0x0 `cgImage`) by falling back
    /// to 1 rather than propagating a broken scale that would make the whole preview vanish.
    private func safeScale(toFitIn available: CGSize) -> CGFloat {
        guard rotatedSize.width > 0, rotatedSize.height > 0 else { return 1 }
        let scale = min(available.width / rotatedSize.width, available.height / rotatedSize.height)
        return scale.isFinite && scale > 0 ? scale : 1
    }
}

#Preview {
    // No real CGImage in a preview context worth faking here — this component's actual visual
    // behavior can only really be checked against a real extracted video frame on-device (see
    // `SessionReviewView`'s "Preview Skeleton" toggle).
    Text("SkeletonImageOverlayView needs a real CGImage — preview via SessionReviewView instead.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding()
}

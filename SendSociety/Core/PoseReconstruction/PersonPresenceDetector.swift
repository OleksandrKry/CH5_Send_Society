import Vision
import UIKit

/// Lightweight "is anyone standing in this shot" check, used by `RecordingView`'s periodic
/// wall-mesh auto-save (see that view's doc comment) to skip saving a frame that would bake a
/// person's body into the wall's point-cloud mesh/texture instead of just the wall surface.
///
/// Deliberately NOT `BodyPose3DExtractor`'s `VNDetectHumanBodyPose3DRequest` — that's a much
/// heavier full-skeleton 3D pose estimate, overkill (and slower) for a plain "is there a person at
/// all" check that needs to run roughly once a second. `VNDetectHumanRectanglesRequest` is
/// Vision's purpose-built, lightweight request for exactly this
/// (https://developer.apple.com/documentation/vision/vndetecthumanrectanglesrequest).
///
/// Deliberately existence-only, NOT position-aware (e.g. "is the person dead-center vs. off to
/// the side"): a single rectangle's position would need the same orientation-hint bookkeeping
/// `BodyPose3DExtractor` has already hit real, hard-to-debug bugs from (see that file's
/// `rotateBearingToRawSensorFrame`/`estimateInitialRotation` history) — not worth that risk for
/// what's meant to be a simple, blunt safety check. If the coach reports the center-vs-edge
/// distinction is genuinely needed in practice, `VNHumanObservation.boundingBox` (normalized,
/// available on every detected result) is where that would be added.
enum PersonPresenceDetector {
    /// Runs on a background queue and calls `completion` on that SAME background queue (callers
    /// that touch `@State`/UI must hop back to the main queue themselves) with whether ANY person
    /// was detected anywhere in the frame.
    static func detectsPerson(
        in pixelBuffer: CVPixelBuffer,
        deviceOrientation: UIDeviceOrientation,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let request = VNDetectHumanRectanglesRequest()
            // Reuses `BodyPose3DExtractor.cameraOrientation(for:)` — the SAME raw-sensor-buffer ->
            // Vision orientation-hint mapping every other Vision request in this app already uses,
            // rather than a second, possibly-drifting copy of that mapping.
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
//                orientation: AppleVisionSkeleton.cameraOrientation(for: deviceOrientation),
                options: [:]
            )
            do {
                try handler.perform([request])
                let found = !(request.results ?? []).isEmpty
                completion(found)
            } catch {
                // Treat a failed request as "couldn't confirm — assume a person might be present"
                // rather than "assume empty," so a transient Vision error never lets a bad
                // (possibly person-containing) frame slip through and corrupt the wall mesh.
                DebugLog.reconstruction.error("PersonPresenceDetector request failed: \(String(describing: error), privacy: .public) — treating as person present, skipping this wall-mesh save")
                completion(true)
            }
        }
    }
}

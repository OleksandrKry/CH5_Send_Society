import Foundation

/// One clickable dot on the video scrubber. It stands for a moment in the video that has
/// something saved on it — a drawing, a 3D pose, or both at once (see
/// `PlaybackEngine.markerMergeWindowSeconds` for how "both at once" is decided).
///
/// This is a plain data struct with NO SwiftUI in it — a designer's new marker UI just needs
/// to read these fields and decide how to draw/color/animate them.
struct SavedMomentMarker: Identifiable {
    let id: UUID
    /// Where this moment sits in the video, in seconds from the start.
    let videoTimeInSeconds: Double
    /// True if there's a saved drawing (pen/line/angle markup) at this moment.
    let hasDrawing: Bool
    /// True if there's a saved 3D pose reconstruction at this moment.
    let has3DPose: Bool
    /// True if the 3D pose was ESTIMATED after the fact (no real depth data), rather than
    /// measured live with LiDAR during recording. Only meaningful when `has3DPose` is true.
    let is3DPoseApproximate: Bool
}

/// PlaybackEngine is the "brain" behind the video review screen. It does NOT import SwiftUI and
/// does NOT know about colors, fonts, buttons, or layout — it only answers two questions a video
/// review screen needs answered:
///
///   1. "What drawing (if any) belongs to this exact moment in the video?"
///   2. "What are ALL the saved moments, so I can put a marker on the scrubber for each one?"
///
/// A View talks to this engine instead of reaching into `RecordingSession` directly. That way,
/// if the front-end design changes completely, this file doesn't have to change at all — only
/// the View does.
///
/// HOW TO WIRE THIS UP (for a new View built around a different design):
///   - When the video pauses, or the scrubber moves while already paused, call
///     `findDrawing(nearVideoTime:)` and show whatever it returns.
///   - When the user finishes drawing something, call `saveDrawing(_:atVideoTime:)`.
///   - To build the scrubber's markers, call `allSavedMoments()` and draw one dot per marker.
///   - When a marker is tapped, seek the video to `marker.videoTimeInSeconds`, then call
///     `findDrawing(nearVideoTime:)` again for that exact time.
/// `@MainActor` because `saveDrawing(_:atVideoTime:)` calls `SessionStore.save()`, which is
/// itself `@MainActor`-isolated (SwiftData's `ModelContext` isn't safe to touch off the main
/// thread) — this engine is only ever created and called from a View anyway (already on the main
/// thread), so this just tells the compiler what was already true.
@MainActor
final class PlaybackEngine {
    /// How close (in seconds) the video's current position needs to be to a saved drawing
    /// before that drawing counts as "the one showing right now." Example: a drawing saved at
    /// 5 seconds will still show anywhere from 4 to 6 seconds.
    static let annotationMatchWindowSeconds: Double = 1.0

    /// How close (in seconds) a saved drawing needs to be to a saved 3D pose before the two are
    /// combined into ONE marker on the scrubber, instead of showing as two separate dots.
    static let markerMergeWindowSeconds: Double = 0.5

    /// nil until a `RecordingSession` has actually been created for this recording — every
    /// function below simply does nothing (or returns empty) until then, rather than erroring.
    private let session: RecordingSession?
    private let sessionStore: SessionStore?

    init(session: RecordingSession?, sessionStore: SessionStore?) {
        self.session = session
        self.sessionStore = sessionStore
    }

    /// Returns the saved drawing closest to `videoTimeInSeconds`, if one exists within
    /// `annotationMatchWindowSeconds`. Returns an empty array (never nil) when nothing is saved
    /// nearby — an empty array just means "draw nothing right now."
    func findDrawing(nearVideoTime videoTimeInSeconds: Double) -> [AnnotationStroke] {
        guard let session else { return [] }
        let closestMatch = session.videoAnnotations.first {
            abs($0.timestampSeconds - videoTimeInSeconds) <= Self.annotationMatchWindowSeconds
        }
        return closestMatch?.strokes ?? []
    }

    /// Saves `strokes` as the drawing for `videoTimeInSeconds` — replacing whatever was saved
    /// nearby before. Passing an empty array deletes the drawing instead of saving an empty one.
    /// Does nothing if there's no session/store to save into yet.
    func saveDrawing(_ strokes: [AnnotationStroke], atVideoTime videoTimeInSeconds: Double) {
        guard let session, let sessionStore else { return }
        session.setVideoAnnotation(timestampSeconds: videoTimeInSeconds, strokes: strokes)
        sessionStore.save()
    }

    /// Builds the full list of scrubber markers by combining every saved drawing and every saved
    /// 3D pose. A drawing within `markerMergeWindowSeconds` of a 3D pose is folded into that
    /// pose's marker (one dot, not two); everything else becomes its own marker. The result is
    /// sorted earliest-to-latest, purely so marker order on screen is stable.
    func allSavedMoments() -> [SavedMomentMarker] {
        guard let session else { return [] }

        var moments: [SavedMomentMarker] = session.reconstructions.map { pose in
            SavedMomentMarker(
                id: pose.id,
                videoTimeInSeconds: pose.timestampSeconds,
                hasDrawing: false,
                has3DPose: true,
                is3DPoseApproximate: pose.isApproximate
            )
        }

        for drawing in session.videoAnnotations {
            if let matchIndex = moments.firstIndex(where: { abs($0.videoTimeInSeconds - drawing.timestampSeconds) <= Self.markerMergeWindowSeconds }) {
                let existingMarker = moments[matchIndex]
                moments[matchIndex] = SavedMomentMarker(
                    id: existingMarker.id,
                    videoTimeInSeconds: existingMarker.videoTimeInSeconds,
                    hasDrawing: true,
                    has3DPose: existingMarker.has3DPose,
                    is3DPoseApproximate: existingMarker.is3DPoseApproximate
                )
            } else {
                moments.append(SavedMomentMarker(
                    id: drawing.id,
                    videoTimeInSeconds: drawing.timestampSeconds,
                    hasDrawing: true,
                    has3DPose: false,
                    is3DPoseApproximate: false
                ))
            }
        }

        return moments.sorted { $0.videoTimeInSeconds < $1.videoTimeInSeconds }
    }
}

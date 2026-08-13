import Foundation
import SwiftData
import simd

/// One saved recording: the video file, the wall scan it was climbed against, and everything the
/// coach marked up or generated while reviewing it — the persisted answer to "save the wall scan
/// result, 2D video annotation, and 3D skeleton position + annotation" (feedback item #3), owned
/// by whichever `UserIdentity` recorded it (feedback item #4 — currently always a guest ID, see
/// `UserIdentity`).
///
/// STORAGE CHOICE: child data (per-timestamp video annotations, per-timestamp 3D reconstructions)
/// is stored as JSON-encoded `Data` blobs on this single model, rather than as separate `@Model`
/// classes wired together with `@Relationship`. SwiftData's relationship macros have real nuances
/// (inverse requirements, cascade-delete syntax, Optional-vs-array handling) that can't be
/// verified without compiling — and a session realistically has a handful of annotated moments
/// and generated reconstructions, not thousands, so there's no real query/performance need for
/// proper relational storage. Flattening to JSON on one model is a smaller, safer slice of
/// SwiftData's API to depend on blind. UNVERIFIED ON DEVICE like everything else in this pass, but
/// deliberately the lowest-risk shape of SwiftData usage available for what this needs to do.
@Model
final class RecordingSession {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var createdAt: Date
    var title: String

    /// Filename only (not a full path) — resolved against `SessionFileStore.videoURL(for:)` at
    /// read time, since the app's container path can change between installs/OS updates.
    var videoFileName: String
    var videoDurationSeconds: Double
    /// `UIDeviceOrientation.rawValue` for the orientation the phone was held in when this
    /// recording started (see `VideoRecorder.recordingDeviceOrientation`'s doc comment) — stored
    /// as a raw `Int` rather than the `UIKit` enum itself so this persistence-model file doesn't
    /// need to import UIKit; reconstruct with `UIDeviceOrientation(rawValue:)` at the point of use.
    /// Feeding this back into Vision when re-generating a reconstruction later (session review's
    /// "Estimate 3D") is what keeps the posture facing the right direction — using the wrong
    /// orientation (or none at all) is exactly what was making re-generated postures come out
    /// rotated relative to a live-generated one.
    ///
    /// DEFAULT VALUE IS LOAD-BEARING: this field was added after the schema had already been run
    /// on-device, with no default — SwiftData's automatic lightweight migration cannot add a new
    /// required column to existing saved rows without one, and silently fails the whole save/fetch
    /// path when it can't (no thrown error anywhere in THIS app's code, no crash — the failure
    /// happens inside SwiftData/CoreData's own migration machinery before any of our code runs).
    /// That's what caused a real on-device regression: recordings stopped persisting at all, with
    /// zero visible error, right after this field was introduced. `0` maps to `UIDeviceOrientation
    /// .unknown` when read back — every read site already falls back sensibly for unrecognized
    /// orientations (see `cameraOrientation(for:)`'s `default: .right` case), so this is a safe,
    /// harmless default, not just a migration workaround. NEVER remove this default from a
    /// `@Model`-stored property without a real migration plan in place.
    var recordingDeviceOrientationRawValue: Int = 0

    /// Folder name (under `SessionFileStore.wallScansDirectory`) holding this session's archived
    /// wall scan — color photo + raw depth/confidence grids + camera pose, enough to rebuild the
    /// SAME bump-detailed point-cloud wall Step 4 would have shown live (see `WallScanArchive`).
    /// nil if Step 1 scanning never produced a usable reference frame for this session.
    var wallScanFolderName: String?

    /// JSON-encoded `[VideoAnnotationEntry]` — see the `videoAnnotations` computed accessor below.
    var videoAnnotationsData: Data
    /// JSON-encoded `[ReconstructionEntry]` — see the `reconstructions` computed accessor below.
    var reconstructionsData: Data

    init(
        id: UUID = UUID(),
        ownerID: UUID,
        createdAt: Date = Date(),
        title: String,
        videoFileName: String,
        videoDurationSeconds: Double,
        recordingDeviceOrientationRawValue: Int,
        wallScanFolderName: String? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.createdAt = createdAt
        self.title = title
        self.videoFileName = videoFileName
        self.videoDurationSeconds = videoDurationSeconds
        self.recordingDeviceOrientationRawValue = recordingDeviceOrientationRawValue
        self.wallScanFolderName = wallScanFolderName
        self.videoAnnotationsData = (try? JSONEncoder().encode([VideoAnnotationEntry]())) ?? Data()
        self.reconstructionsData = (try? JSONEncoder().encode([ReconstructionEntry]())) ?? Data()
    }

    var videoAnnotations: [VideoAnnotationEntry] {
        get { (try? JSONDecoder().decode([VideoAnnotationEntry].self, from: videoAnnotationsData)) ?? [] }
        set { videoAnnotationsData = (try? JSONEncoder().encode(newValue)) ?? videoAnnotationsData }
    }

    var reconstructions: [ReconstructionEntry] {
        get { (try? JSONDecoder().decode([ReconstructionEntry].self, from: reconstructionsData)) ?? [] }
        set { reconstructionsData = (try? JSONEncoder().encode(newValue)) ?? reconstructionsData }
    }

    /// Upserts a video annotation for `timestampSeconds`, replacing whatever was previously saved
    /// within `mergeToleranceSeconds` of it — so scrubbing to a slightly different position on a
    /// later visit updates the existing markup instead of piling up near-duplicate entries.
    /// Saving an empty stroke list deletes the entry rather than keeping an empty placeholder.
    ///
    /// Default widened to 1.0s (from an earlier 0.3s) to match the ±1s "show the saved annotation
    /// while scrubbing near it" window `PlaybackView`/`SessionReviewView` now load with — an edit
    /// made anywhere inside that same ±1s window should update the ONE entry currently being
    /// shown, not create a near-duplicate a few tenths of a second away.
    func setVideoAnnotation(timestampSeconds: Double, strokes: [AnnotationStroke], mergeToleranceSeconds: Double = 1.0) {
        var all = videoAnnotations
        if let index = all.firstIndex(where: { abs($0.timestampSeconds - timestampSeconds) <= mergeToleranceSeconds }) {
            if strokes.isEmpty {
                all.remove(at: index)
            } else {
                all[index].strokes = strokes
                all[index].timestampSeconds = timestampSeconds
            }
        } else if !strokes.isEmpty {
            all.append(VideoAnnotationEntry(timestampSeconds: timestampSeconds, strokes: strokes))
        }
        videoAnnotations = all
    }

    /// Upserts a reconstruction for `entry.timestampSeconds` — same nearest-timestamp merge idea
    /// as `setVideoAnnotation`, so re-generating at almost the same scrub position updates the
    /// existing saved reconstruction instead of creating a near-duplicate.
    func upsertReconstruction(_ entry: ReconstructionEntry, mergeToleranceSeconds: Double = 0.3) {
        var all = reconstructions
        if let index = all.firstIndex(where: { abs($0.timestampSeconds - entry.timestampSeconds) <= mergeToleranceSeconds }) {
            all[index] = entry
        } else {
            all.append(entry)
        }
        reconstructions = all
    }

    /// Deletes one saved reconstruction by `id` — lets a coach clear out a specific timeframe's
    /// generated/estimated 3D result (e.g. a bad test run) so `SessionReviewView` shows "Estimate 3D
    /// View" / "Generate" again for that moment instead of "View 3D Reconstruction", allowing a
    /// clean retest. No-op if `id` isn't found (already deleted, or never existed).
    func removeReconstruction(id: UUID) {
        reconstructions.removeAll { $0.id == id }
    }
}

/// One paused moment's 2D screen-space markup during video playback — feedback item #1.
struct VideoAnnotationEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var timestampSeconds: Double
    var strokes: [AnnotationStroke]
}

/// One generated (and possibly since hand-corrected/annotated) 3D reconstruction at a specific
/// video timestamp — the persisted answer to feedback item #2's "indicator in specific frame if
/// that's already 3d generated." Holds everything needed to redraw this exact reconstruction
/// WITHOUT re-running Vision or needing real depth data again.
///
/// BOUNDARY, updated now that session review can generate NEW reconstructions too (see
/// `SessionReviewView`'s "Estimate 3D" action): a moment generated live (during the original
/// recording) has `isApproximate == false` — its `worldPositions` are grounded in that exact
/// frame's real LiDAR depth, the same as Step 4 always did. A moment generated later, from
/// review, has `isApproximate == true` — Vision runs on a frame pulled straight out of the saved
/// video file (see `VideoFrameExtractor`), and since real per-frame depth/camera-pose data only
/// ever existed in memory during the original live AR session (see `RecordedFrameStore`) and was
/// never persisted, that reconstruction is placed using Vision's own monocular estimate PLUS the
/// wall's single archived reference camera position as a stand-in for "roughly where the camera
/// was" — noticeably less precise than a live-grounded one. `isApproximate` is what lets the UI
/// say so honestly rather than presenting an estimate with the same confidence as a real
/// measurement.
struct ReconstructionEntry: Identifiable {
    var id: UUID = UUID()
    var timestampSeconds: Double
    /// The FINAL, already depth-grounded (or, if `isApproximate`, Vision-estimated) world-space
    /// joint positions used to render this reconstruction — NOT the raw `BodyPoseSample`/camera
    /// transform, which are useless without the original live LiDAR depth data to re-ground them
    /// against (see this type's doc comment). Also doubles as `SkeletonPoseEditor`'s ROM-constraint
    /// reference direction if the coach edits this pose again after reloading it.
    var worldPositions: [BodyJointName: SIMD3<Float>]
    /// The coach's manually-dragged pose (see `SkeletonPoseEditor`), if they edited it — nil means
    /// "just show `worldPositions` as detected."
    var jointOverrides: [BodyJointName: SIMD3<Float>]?
    /// This reconstruction's own 3D-view annotations (see `ReconstructionView`'s Annotate mode) —
    /// separate from `VideoAnnotationEntry`'s 2D video-playback markup.
    var annotationStrokes: [AnnotationStroke] = []
    /// True for a reconstruction generated later, from `SessionReviewView`, instead of live during
    /// the original recording — see this type's doc comment. Defaults to `false` so older saved
    /// entries (from before this field existed) decode as "live-quality" — which is what they are.
    var isApproximate: Bool = false
}

/// Manual `Codable` — `worldPositions`/`jointOverrides`'s `SIMD3<Float>` values need
/// `CodableSIMD.swift`'s conformance, which Swift's automatic synthesis failed to recognize across
/// files (see `WallScanArchive.Metadata`'s doc comment). Writing this by hand sidesteps that.
extension ReconstructionEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, timestampSeconds, worldPositions, jointOverrides
        case annotationStrokes, isApproximate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestampSeconds = try container.decode(Double.self, forKey: .timestampSeconds)
        worldPositions = try container.decode([BodyJointName: SIMD3<Float>].self, forKey: .worldPositions)
        jointOverrides = try container.decodeIfPresent([BodyJointName: SIMD3<Float>].self, forKey: .jointOverrides)
        annotationStrokes = try container.decodeIfPresent([AnnotationStroke].self, forKey: .annotationStrokes) ?? []
        isApproximate = try container.decodeIfPresent(Bool.self, forKey: .isApproximate) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestampSeconds, forKey: .timestampSeconds)
        try container.encode(worldPositions, forKey: .worldPositions)
        try container.encodeIfPresent(jointOverrides, forKey: .jointOverrides)
        try container.encode(annotationStrokes, forKey: .annotationStrokes)
        try container.encode(isApproximate, forKey: .isApproximate)
    }
}

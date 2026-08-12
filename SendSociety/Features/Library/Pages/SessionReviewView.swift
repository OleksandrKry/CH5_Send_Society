import SwiftUI
import AVKit
import ARKit
import simd
import UIKit
import SwiftData

/// Reopens a saved `RecordingSession` — the video plays back with its saved 2D annotations
/// reappearing at their timestamps, the scrubber shows tick marks for moments that already have a
/// 3D reconstruction, and tapping a marked moment reloads that EXACT saved reconstruction (via
/// `SavedReconstructionReviewView`) without touching Vision at all.
///
/// A moment with NO saved reconstruction can still get one via "Estimate 3D View"
/// (`generateEstimate()`) — pulling that exact frame out of the saved video file
/// (`VideoFrameExtractor`) and running Vision on it fresh. This is real, but strictly
/// LOWER-FIDELITY than what Step 4 produces live: the original per-frame LiDAR depth/camera-pose
/// data only ever existed in memory during the original AR session (see `RecordedFrameStore`) and
/// was never persisted, so there's no real depth to ground the skeleton in here — it's placed
/// using Vision's own monocular estimate plus the wall's single archived reference camera position
/// as a stand-in for "roughly where the camera was." Every entry this produces is flagged
/// `isApproximate` so the coach always sees an honest "estimated" label, never a confident-looking
/// wrong answer.
struct SessionReviewView: View {
    let session: RecordingSession
    let sessionStore: SessionStore
    let onClose: () -> Void

    private let videoURL: URL
    @StateObject private var model: PlaybackModel
    @StateObject private var annotationState = AnnotationState()
    @State private var isAnnotating = false
    @State private var annotatedTimestamp: Double = 0
    @State private var wallTextureReference: ARSessionManager.WallTextureReference?
    @State private var reviewingEntry: ReconstructionEntry?
    @State private var isGeneratingEstimate = false
    @State private var estimateError: String?
    /// Set while confirming a delete of `nearbyEntry` — a separate `@State` rather than reusing
    /// `reviewingEntry` so the confirmation can't accidentally trigger from an unrelated sheet
    /// presentation. Deletion is destructive/unrecoverable (overwrites the saved JSON blob), so
    /// this always goes through `.confirmationDialog` rather than deleting on first tap.
    @State private var pendingDeleteEntry: ReconstructionEntry?
    /// True while "Preview Skeleton" is toggled on — see `refreshSkeletonPreview()` and
    /// `skeletonPreview`'s doc comment for how this lets a coach sanity-check a backend's raw
    /// detection on the current paused frame before committing to Estimate/Generate 3D.
    @State private var isPreviewingSkeleton = false
    @State private var skeletonPreview: SkeletonPreviewResult?
    @State private var isLoadingSkeletonPreview = false
    @State private var skeletonPreviewError: String?
    /// Which backend the preview runs — independent of `PoseDetectionSettings.useYOLO` (which
    /// only affects Step 2/Step 4) on purpose: comparing Vision vs. YOLO on the same paused frame
    /// is exactly what this preview is for, and forcing a full rebuild just to flip that global
    /// switch would defeat the point on a device with no compiler access. Defaults to Vision to
    /// match the app's own safe default.
    @State private var previewBackend: PreviewBackend = .vision

    private enum PreviewBackend: String, CaseIterable, Identifiable {
        case vision = "Vision"
        case yolo = "YOLO"
        var id: String { rawValue }
    }

    /// One "Preview Skeleton" result: the exact raw frame that was analyzed, plus whatever 2D
    /// joint points the selected backend found in it (empty, not nil, when the frame read fine
    /// but no person was detected — see `SkeletonImageOverlayView`'s doc comment for why that's
    /// still a useful, honest answer to show). `timestampSeconds`/`backend` let
    /// `refreshSkeletonPreview()` skip redundant re-detection only when NEITHER the paused
    /// position NOR the selected backend has actually changed.
    private struct SkeletonPreviewResult {
        let image: CGImage
        let points: [BodyJointName: CGPoint]
        let timestampSeconds: Double
        let backend: PreviewBackend
    }

    init(session: RecordingSession, sessionStore: SessionStore, onClose: @escaping () -> Void) {
        self.session = session
        self.sessionStore = sessionStore
        self.onClose = onClose
        let url = sessionStore.videoURL(for: session)
        self.videoURL = url
        _model = StateObject(wrappedValue: PlaybackModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Label("Library", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                Spacer()
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Color.clear.frame(width: 44) // balances the back button so the title stays centered
            }
            .padding()

            ZStack {
                // Skeleton preview REPLACES the live player (rather than overlaying on top of
                // it) while active — both the still frame and the projected points come from the
                // exact same extracted `CGImage`, so they're guaranteed pixel-aligned; overlaying
                // on top of the separately-rendered live `VideoPlayer` instead could only ever be
                // "close" (different rendering/letterboxing pipeline), which would undermine the
                // entire point of a "does this actually look right" sanity check.
                if isPreviewingSkeleton, !model.isPlaying, let skeletonPreview {
                    SkeletonImageOverlayView(
                        cgImage: skeletonPreview.image,
                        points: skeletonPreview.points,
                        deviceOrientation: UIDeviceOrientation(rawValue: session.recordingDeviceOrientationRawValue) ?? .portrait
                    )
                } else {
                    VideoPlayer(player: model.player)
                }
                if isPreviewingSkeleton, !model.isPlaying, isLoadingSkeletonPreview {
                    ProgressView("Detecting pose…")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if isPreviewingSkeleton, !model.isPlaying, let skeletonPreviewError {
                    Text(skeletonPreviewError)
                        .font(.caption)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else if isPreviewingSkeleton, !model.isPlaying, let skeletonPreview, skeletonPreview.points.isEmpty, !isLoadingSkeletonPreview {
                    VStack {
                        Spacer()
                        Text("No person detected in this frame.")
                            .font(.caption)
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(.bottom, 8)
                    }
                }
                if isAnnotating {
                    AnnotationOverlay(state: annotationState)
                    if !model.isPlaying {
                        VStack {
                            Spacer()
                            AnnotationToolbar(state: annotationState)
                                .padding(.bottom, 12)
                        }
                    }
                }
            }

            VStack(spacing: 12) {
                reconstructionMarkerTrack
                Slider(
                    value: Binding(
                        get: { model.currentTime },
                        set: { model.seek(to: $0) }
                    ),
                    in: 0...max(model.duration, 0.01),
                    onEditingChanged: { editing in
                        if editing { model.pause() }
                    }
                )
                if isPreviewingSkeleton, !model.isPlaying {
                    // Independent of `PoseDetectionSettings.useYOLO` on purpose — see
                    // `previewBackend`'s doc comment. Switching here re-runs detection on the SAME
                    // paused frame with the other backend, so this is the direct way to compare
                    // Vision vs. YOLO accuracy without touching Step 2/Step 4 at all.
                    Picker("Preview backend", selection: $previewBackend) {
                        ForEach(PreviewBackend.allCases) { backend in
                            Text(backend.rawValue).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: previewBackend) { _, _ in refreshSkeletonPreview() }
                }
                HStack {
                    Text(model.isPlaying ? "Playing" : "Paused")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !model.isPlaying {
                        Button {
                            isPreviewingSkeleton.toggle()
                            if isPreviewingSkeleton { refreshSkeletonPreview() }
                        } label: {
                            Label("Preview Skeleton", systemImage: "figure.walk")
                        }
                        .buttonStyle(.bordered)
                        .tint(isPreviewingSkeleton ? .green : nil)
                        .font(.footnote)
                        Button {
                            isAnnotating.toggle()
                        } label: {
                            Label("Annotate", systemImage: "pencil.tip")
                        }
                        .buttonStyle(.bordered)
                        .tint(isAnnotating ? .orange : nil)
                        .font(.footnote)
                    }
                    Button(model.isPlaying ? "Pause" : "Play") {
                        model.isPlaying ? model.pause() : model.play()
                    }
                }

                if !model.isPlaying {
                    reconstructionAction
                }
            }
            .padding()
        }
        .onAppear {
            wallTextureReference = sessionStore.wallTextureReference(for: session)
            loadAnnotationsForCurrentTime()
        }
        .onChange(of: model.isPlaying) { _, isPlaying in
            if !isPlaying { loadAnnotationsForCurrentTime() }
        }
        .onChange(of: model.currentTime) { _, _ in
            // Fires ~30x/sec during actual playback too (see `PlaybackModel.currentTime`'s doc
            // comment) — `refreshSkeletonPreview()` bails immediately in that case, so this is a
            // cheap no-op except right after a scrub/seek while paused, which is exactly when a
            // stale preview needs refreshing.
            refreshSkeletonPreview()
        }
        .onChange(of: annotationState.strokes) { _, newValue in
            session.setVideoAnnotation(timestampSeconds: annotatedTimestamp, strokes: newValue)
            sessionStore.save()
        }
        .fullScreenCover(item: $reviewingEntry) { entry in
            SavedReconstructionReviewView(
                entry: entry,
                session: session,
                sessionStore: sessionStore,
                wallTextureReference: wallTextureReference,
                onClose: { reviewingEntry = nil }
            )
        }
    }

    /// The saved reconstruction nearest the current paused position, if any is close enough to
    /// count as "this moment" — same 0.3s tolerance `RecordingSession`'s own upsert methods use.
    private var nearbyEntry: ReconstructionEntry? {
        session.reconstructions.first { abs($0.timestampSeconds - model.currentTime) <= 0.3 }
    }

    @ViewBuilder
    private var reconstructionAction: some View {
        if let nearbyEntry {
            HStack(spacing: 8) {
                Button {
                    reviewingEntry = nearbyEntry
                } label: {
                    Text("View 3D Reconstruction")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                // Lets a coach clear out a bad/test generation for this exact moment without
                // opening the full 3D view first — tapping this shows "Estimate 3D View" (or,
                // once Step 4's live Generate flow is reopened for the same session, "Generate")
                // again for a clean retest, instead of a stuck "View 3D Reconstruction".
                Button(role: .destructive) {
                    pendingDeleteEntry = nearbyEntry
                } label: {
                    Image(systemName: "trash")
                        .font(.headline)
                        .padding()
                        .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.red)
                }
            }
            .confirmationDialog(
                "Delete this 3D reconstruction?",
                isPresented: Binding(
                    get: { pendingDeleteEntry != nil },
                    set: { if !$0 { pendingDeleteEntry = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let pendingDeleteEntry {
                        session.removeReconstruction(id: pendingDeleteEntry.id)
                        sessionStore.save()
                    }
                    pendingDeleteEntry = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteEntry = nil
                }
            } message: {
                Text("This removes the saved 3D position for this moment so you can generate it again. This can't be undone.")
            }
        } else if isGeneratingEstimate {
            HStack {
                ProgressView()
                Text("Estimating 3D pose…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            VStack(spacing: 8) {
                Button {
                    generateEstimate()
                } label: {
                    Text("Estimate 3D View")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                Text("No LiDAR depth for this moment — this uses Vision's own estimate instead of a precise measurement, and won't classify hand grips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let estimateError {
                    Text(estimateError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// Pulls the current paused frame out of the saved video and runs Vision on it fresh — the
    /// actual algorithm lives in `ReconstructionEstimator` (Core/PoseReconstruction), not here; this
    /// is just wiring the screen's current state to it and updating UI state with the result. Runs
    /// off the main thread since frame extraction + Vision can take a noticeable moment.
    private func generateEstimate() {
        isGeneratingEstimate = true
        estimateError = nil
        let timestamp = model.currentTime
        let url = videoURL
        let reference = wallTextureReference
        // MUST be the orientation the phone was actually held in during this recording, not a
        // fixed assumption — see `ReconstructionEstimator.estimate`'s doc comment for why.
        let deviceOrientation = UIDeviceOrientation(rawValue: session.recordingDeviceOrientationRawValue) ?? .portrait
        // The climber's Step 2 measured limb lengths (nil if Step 2 was skipped) — this path has
        // NO real depth at all, so it's the most likely to need this correction. See
        // `CalibrationScaleCorrection`'s doc comment.
        let calibratedSegments = session.calibration?.segments

        // Dispatched through `YOLOBodyPoseDetector.queue`, NOT `.global(qos: .userInitiated)` —
        // `ReconstructionEstimator.estimate` always runs the YOLO+Vision hybrid (never gated by
        // `PoseDetectionSettings.useYOLO`), so this call needs the same queue-isolation fix as
        // the skeleton preview below — see `YOLOBodyPoseDetector.queue`'s doc comment for why.
        YOLOBodyPoseDetector.queue.async {
            do {
                let entry = try ReconstructionEstimator.estimate(
                    videoURL: url,
                    atSeconds: timestamp,
                    deviceOrientation: deviceOrientation,
                    wallReference: reference,
                    calibratedSegments: calibratedSegments
                )
                DispatchQueue.main.async {
                    session.upsertReconstruction(entry)
                    sessionStore.save()
                    isGeneratingEstimate = false
                    // Not surfaced as `estimateError` — setting `reviewingEntry` immediately
                    // presents `SavedReconstructionReviewView` (see its `.fullScreenCover(item:)`
                    // below), so an error message here would never actually be seen. That's fine
                    // even for a wall-only (no-climber) entry — the wall-only view itself is the
                    // useful result, not an error state.
                    reviewingEntry = entry
                }
            } catch {
                DispatchQueue.main.async {
                    isGeneratingEstimate = false
                    estimateError = "Couldn't read a frame from the video at this moment."
                }
            }
        }
    }

    /// Pulls the current paused frame and runs Vision on it fresh, purely to draw a 2D skeleton
    /// overlay for a sanity check — completely separate from `generateEstimate()`, which builds a
    /// real, saved `ReconstructionEntry`. Nothing here is saved; this is disposable, look-then-
    /// discard feedback for deciding whether a moment is even worth spending an Estimate/Generate
    /// 3D on. Runs off the main thread since frame extraction + Vision can take a noticeable
    /// moment, same as `generateEstimate()`.
    private func refreshSkeletonPreview() {
        guard isPreviewingSkeleton, !model.isPlaying else { return }
        let timestamp = model.currentTime
        let backend = previewBackend
        // Already showing exactly this moment with the same backend — nothing changed, skip the
        // redundant re-detection (this handler also fires on unrelated `currentTime` jitter from
        // `PlaybackModel`'s periodic time observer settling right after a seek, and now also on
        // `previewBackend` switching, which SHOULD force a fresh detection on the same frame).
        if let skeletonPreview, skeletonPreview.backend == backend, abs(skeletonPreview.timestampSeconds - timestamp) < 0.05 { return }

        guard let reference = wallTextureReference else {
            skeletonPreviewError = "No wall scan camera data saved for this session — can't place the skeleton preview."
            skeletonPreview = nil
            return
        }

        isLoadingSkeletonPreview = true
        skeletonPreviewError = nil
        let url = videoURL
        // Same reasoning as `generateEstimate()`: MUST be this recording's own saved orientation,
        // not a live/current read — see `ReconstructionEstimator.estimate`'s doc comment.
        let deviceOrientation = UIDeviceOrientation(rawValue: session.recordingDeviceOrientationRawValue) ?? .portrait
        let intrinsics = reference.intrinsics
        let imageResolution = reference.imageResolution

        // Dispatched through `YOLOBodyPoseDetector.queue`, NOT `.global(qos: .userInitiated)` —
        // even when `backend == .vision` this frame's extraction/Vision work still runs here, but
        // routing EVERY preview through the same queue keeps this simple and correct regardless
        // of which backend is selected — see `YOLOBodyPoseDetector.queue`'s doc comment for why
        // this matters specifically for the `.yolo` case.
        YOLOBodyPoseDetector.queue.async {
            guard let cgImage = VideoFrameExtractor.extractFrame(from: url, atSeconds: timestamp) else {
                DispatchQueue.main.async {
                    isLoadingSkeletonPreview = false
                    skeletonPreviewError = "Couldn't read a frame from the video at this moment."
                    skeletonPreview = nil
                }
                return
            }
            var points: [BodyJointName: CGPoint] = [:]
            // Only a genuine "no person in this frame" result is treated as the honest, silent
            // empty-points answer (same as `ReconstructionEstimator.estimate`'s wall-only-entry
            // handling) — anything else (model load failure/timeout, etc.) gets surfaced directly
            // in `skeletonPreviewError` instead of silently reading as "no person detected," which
            // would be misleading to debug against.
            var detectionErrorMessage: String?
            switch backend {
            case .vision:
                do {
                    let sample = try BodyPose3DExtractor.detect(inVideoFrame: cgImage, deviceOrientation: deviceOrientation)
                    points = BodyPose3DExtractor.projected2DImagePoints(
                        from: sample,
                        intrinsics: intrinsics,
                        imageResolution: imageResolution,
                        deviceOrientation: deviceOrientation
                    )
                } catch BodyPoseError.noPersonDetected {
                    // Honest empty result — nothing to surface.
                } catch {
                    detectionErrorMessage = "Vision detection failed: \(error.localizedDescription)"
                }
            case .yolo:
                // No projection step needed here (unlike Vision above) — YOLO's `.xy` output
                // already lands in the same raw/unrotated pixel space `cgImage` is in, same as
                // every other YOLO pixel-joint consumer (`groundPixelJoints`,
                // `worldJointPositions(fromPixelJoints:...)`). See `YOLOBodyPoseDetector`'s
                // "COORDINATE SPACE NOTE" doc comment.
                do {
                    let joints = try YOLOBodyPoseDetector.detect(in: cgImage)
                    points = joints.mapValues(\.point)
                } catch YOLOBodyPoseDetector.DetectionError.noPersonDetected {
                    // Honest empty result — nothing to surface.
                } catch {
                    detectionErrorMessage = error.localizedDescription
                }
            }
            DispatchQueue.main.async {
                isLoadingSkeletonPreview = false
                if let detectionErrorMessage {
                    skeletonPreviewError = detectionErrorMessage
                    skeletonPreview = nil
                } else {
                    skeletonPreview = SkeletonPreviewResult(image: cgImage, points: points, timestampSeconds: timestamp, backend: backend)
                }
            }
        }
    }

    private func loadAnnotationsForCurrentTime() {
        annotatedTimestamp = model.currentTime
        let nearest = session.videoAnnotations.first { abs($0.timestampSeconds - model.currentTime) <= 0.3 }
        annotationState.load(strokes: nearest?.strokes ?? [])
    }

    @ViewBuilder
    private var reconstructionMarkerTrack: some View {
        if !session.reconstructions.isEmpty, model.duration > 0 {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    ForEach(session.reconstructions) { entry in
                        let fraction = min(max(entry.timestampSeconds / model.duration, 0), 1)
                        Circle()
                            .fill(entry.isApproximate ? Color.orange : Color.teal)
                            .frame(width: 6, height: 6)
                            .offset(x: geometry.size.width * fraction - 3)
                    }
                }
            }
            .frame(height: 8)
        }
    }
}

// `SavedReconstructionReviewView` (the fullScreenCover destination that renders a single saved
// `ReconstructionEntry`) has moved to Features/Library/Pages/SavedReconstructionReviewView.swift —
// it's a distinct, self-contained screen rather than a piece of this page's own layout.

// Preview note: an in-memory, unmanaged `RecordingSession` with no real video file behind it —
// the player area won't show real footage, but the scrubber/annotate/estimate-3D controls all
// render normally, which is enough to check this screen's layout.
#Preview {
    let container = try! ModelContainer(for: RecordingSession.self, configurations: .init(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    let session = RecordingSession(
        ownerID: UUID(),
        title: "Preview Climb",
        videoFileName: "preview.mp4",
        videoDurationSeconds: 42,
        recordingDeviceOrientationRawValue: 1
    )
    return SessionReviewView(session: session, sessionStore: SessionStore(modelContext: context), onClose: {})
}

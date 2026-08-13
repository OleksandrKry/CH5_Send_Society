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

    /// One "Preview Skeleton" result: the exact raw frame that was analyzed, plus whatever 2D
    /// joint points Vision found in it (empty, not nil, when the frame read fine but no person
    /// was detected — see `SkeletonImageOverlayView`'s doc comment for why that's still a useful,
    /// honest answer to show). `timestampSeconds` lets `refreshSkeletonPreview()` skip redundant
    /// re-detection only when the paused position hasn't actually changed.
    private struct SkeletonPreviewResult {
        let image: CGImage
        let points: [BodyJointName: CGPoint]
        let timestampSeconds: Double
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
                } else if !isPreviewingSkeleton, !model.isPlaying, !annotationState.strokes.isEmpty {
                    // Auto-preview: same reasoning as `PlaybackView` — a saved annotation within
                    // ±1s of wherever the scrubber landed shows up on its own, read-only
                    // (`isInteractive: false`), without needing "Annotate" tapped first. Skipped
                    // while the skeleton preview is showing (that view already replaces the video
                    // player entirely — see the `ZStack`'s first branch above) so this doesn't draw
                    // stale markup over an unrelated still frame.
                    AnnotationOverlay(state: annotationState, isInteractive: false)
                }
            }

            VStack(spacing: 12) {
                savedMomentMarkerTrack
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
                Text("No LiDAR depth for this moment — this uses Vision's own estimate instead of a precise measurement.")
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

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entry = try ReconstructionEstimator.estimate(
                    videoURL: url,
                    atSeconds: timestamp,
                    deviceOrientation: deviceOrientation,
                    wallReference: reference
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
        // Already showing exactly this moment — nothing changed, skip the redundant re-detection
        // (this handler also fires on unrelated `currentTime` jitter from `PlaybackModel`'s
        // periodic time observer settling right after a seek).
        if let skeletonPreview, abs(skeletonPreview.timestampSeconds - timestamp) < 0.05 { return }

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

        DispatchQueue.global(qos: .userInitiated).async {
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
            DispatchQueue.main.async {
                isLoadingSkeletonPreview = false
                if let detectionErrorMessage {
                    skeletonPreviewError = detectionErrorMessage
                    skeletonPreview = nil
                } else {
                    skeletonPreview = SkeletonPreviewResult(image: cgImage, points: points, timestampSeconds: timestamp)
                }
            }
        }
    }

    private func loadAnnotationsForCurrentTime() {
        loadAnnotations(at: model.currentTime)
    }

    /// Loads whatever's saved within ±1s of `timestamp` — see `PlaybackView.loadAnnotations(at:)`'s
    /// doc comment for the full reasoning (same ±1s window, same "explicit timestamp rather than
    /// racing `model.currentTime`" logic, shared here so `jump(to:)` below can seek and preview a
    /// tapped marker's annotation reliably).
    private func loadAnnotations(at timestamp: Double) {
        annotatedTimestamp = timestamp
        let nearest = session.videoAnnotations.first { abs($0.timestampSeconds - timestamp) <= 1.0 }
        annotationState.load(strokes: nearest?.strokes ?? [])
    }

    /// One tappable moment on the scrubber's marker track — see `PlaybackView.SavedMoment`'s doc
    /// comment for the merge reasoning (an annotation within 0.5s of a reconstruction folds into
    /// that reconstruction's marker rather than showing as a separate dot).
    private struct SavedMoment: Identifiable {
        let id: UUID
        let timestampSeconds: Double
        let hasAnnotation: Bool
        let hasReconstruction: Bool
        let isApproximateReconstruction: Bool
    }

    private var savedMoments: [SavedMoment] {
        var moments: [SavedMoment] = session.reconstructions.map {
            SavedMoment(id: $0.id, timestampSeconds: $0.timestampSeconds, hasAnnotation: false, hasReconstruction: true, isApproximateReconstruction: $0.isApproximate)
        }
        for annotation in session.videoAnnotations {
            if let index = moments.firstIndex(where: { abs($0.timestampSeconds - annotation.timestampSeconds) <= 0.5 }) {
                let existing = moments[index]
                moments[index] = SavedMoment(id: existing.id, timestampSeconds: existing.timestampSeconds, hasAnnotation: true, hasReconstruction: existing.hasReconstruction, isApproximateReconstruction: existing.isApproximateReconstruction)
            } else {
                moments.append(SavedMoment(id: annotation.id, timestampSeconds: annotation.timestampSeconds, hasAnnotation: true, hasReconstruction: false, isApproximateReconstruction: false))
            }
        }
        return moments.sorted { $0.timestampSeconds < $1.timestampSeconds }
    }

    /// Seeks straight to `moment`'s timestamp and shows whatever it has: a reconstruction opens
    /// `SavedReconstructionReviewView` directly (via `reviewingEntry`'s existing
    /// `.fullScreenCover(item:)` below) using the EXACT saved entry (matched by id, not a fresh
    /// nearby-lookup) rather than re-running any detection; an annotation-only moment relies on the
    /// auto-preview above to show its strokes once the seek lands (paused, since
    /// `PlaybackModel.seek(to:)` always pauses first).
    private func jump(to moment: SavedMoment) {
        model.seek(to: moment.timestampSeconds)
        loadAnnotations(at: moment.timestampSeconds)
        if moment.hasReconstruction, let entry = session.reconstructions.first(where: { $0.id == moment.id }) {
            reviewingEntry = entry
        }
    }

    /// Tappable markers for every saved moment — see `PlaybackView.savedMomentMarkerTrack`'s doc
    /// comment for the full "larger and clickable" reasoning; same icon/color scheme here.
    @ViewBuilder
    private var savedMomentMarkerTrack: some View {
        if !savedMoments.isEmpty, model.duration > 0 {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    ForEach(savedMoments) { moment in
                        let fraction = min(max(moment.timestampSeconds / model.duration, 0), 1)
                        Button {
                            jump(to: moment)
                        } label: {
                            Image(systemName: moment.hasReconstruction ? "cube.fill" : "pencil.tip.crop.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(
                                    (moment.hasReconstruction ? (moment.isApproximateReconstruction ? Color.orange : Color.teal) : Color.orange),
                                    in: Circle()
                                )
                        }
                        .offset(x: geometry.size.width * fraction - 13)
                    }
                }
            }
            .frame(height: 26)
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

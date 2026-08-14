import SwiftUI
import AVKit
import ARKit
import simd
import UIKit
import SwiftData

/// Reopens a saved `RecordingSession` — the video plays back with its saved drawings reappearing
/// near their timestamps, the scrubber shows tappable markers for moments that already have a
/// saved drawing and/or a 3D pose, and tapping a 3D-pose marker reloads that EXACT saved
/// reconstruction (via `SavedReconstructionReviewView`) without touching Vision at all.
///
/// A moment with NO saved reconstruction can still get one via "Estimate 3D View" — pulling that
/// exact frame out of the saved video file and running Vision on it fresh. This is real, but
/// strictly LOWER-FIDELITY than what Step 4 produces live: the original per-frame LiDAR depth/
/// camera-pose data only ever existed in memory during the original AR session and was never
/// persisted, so there's no real depth to ground the skeleton in here — it's placed using
/// Vision's own monocular estimate plus the wall's single archived reference camera position as a
/// stand-in for "roughly where the camera was." Every entry this produces is flagged
/// `isApproximate` so the coach always sees an honest "estimated" label, never a confident-looking
/// wrong answer.
///
/// THIS FILE IS UI ONLY. It never searches saved drawings/reconstructions or runs Vision itself —
/// it asks `PlaybackEngine` (drawings + markers) and `SessionReviewEngine` (3D pose estimate +
/// skeleton preview) for answers. If you're redesigning this screen's look, this is the only file
/// you should need to touch.
struct SessionReviewView: View {
    // MARK: - Given to this screen from outside

    let session: RecordingSession
    let sessionStore: SessionStore
    let onClose: () -> Void

    // MARK: - The "brains" this screen talks to

    private let videoURL: URL
    /// Plays/pauses/seeks the video.
    @StateObject private var videoModel: PlaybackModel
    /// Holds whatever drawing is CURRENTLY on screen.
    @StateObject private var drawingState = AnnotationState()
    /// Finds/saves drawings by video timestamp, and builds the scrubber's marker list — the SAME
    /// engine `PlaybackView` uses (Features/Recording/Pages/PlaybackEngine.swift), reused here
    /// since this screen needs exactly the same two things from it.
    private let drawingEngine: PlaybackEngine
    /// Generates 3D pose estimates and skeleton previews, and finds/deletes saved 3D poses — see
    /// SessionReviewEngine.swift.
    private let reviewEngine: SessionReviewEngine

    // MARK: - Plain on-screen state (just "what's toggled/loaded," no logic)

    @State private var isDrawingModeOn = false
    /// The video timestamp `drawingState` currently belongs to — so a new drawing gets saved
    /// under the moment it was actually drawn at, not wherever the scrubber has since moved to.
    @State private var currentDrawingVideoTime: Double = 0
    @State private var wallTextureReference: ARSessionManager.WallTextureReference?
    @State private var reviewingEntry: ReconstructionEntry?
    @State private var isGeneratingEstimate = false
    @State private var estimateErrorMessage: String?
    /// Set while confirming a delete — a separate `@State` rather than reusing `reviewingEntry`
    /// so the confirmation can't accidentally trigger from an unrelated sheet presentation.
    @State private var pendingDeleteEntry: ReconstructionEntry?
    /// True while "Preview Skeleton" is toggled on — lets a coach sanity-check Vision's raw
    /// detection on the current paused frame before committing to Estimate/Generate 3D.
    @State private var isPreviewingSkeleton = false
    @State private var skeletonPreview: SkeletonPreviewResult?
    @State private var isLoadingSkeletonPreview = false
    @State private var skeletonPreviewErrorMessage: String?

    /// The orientation the phone was actually held in during THIS recording — always read from
    /// the saved session, never the live device orientation, since a coach could be reviewing
    /// this in a completely different orientation than they recorded in.
    private var recordingDeviceOrientation: UIDeviceOrientation {
        UIDeviceOrientation(rawValue: session.recordingDeviceOrientationRawValue) ?? .portrait
    }

    init(session: RecordingSession, sessionStore: SessionStore, onClose: @escaping () -> Void) {
        self.session = session
        self.sessionStore = sessionStore
        self.onClose = onClose
        let url = sessionStore.videoURL(for: session)
        self.videoURL = url
        _videoModel = StateObject(wrappedValue: PlaybackModel(url: url))
        drawingEngine = PlaybackEngine(session: session, sessionStore: sessionStore)
        reviewEngine = SessionReviewEngine(session: session, sessionStore: sessionStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            videoArea
            controlsArea
        }
        .onAppear {
            wallTextureReference = sessionStore.wallTextureReference(for: session)
            refreshDrawingForCurrentVideoTime()
        }
        .onChange(of: videoModel.isPlaying) { _, isPlaying in
            if !isPlaying { refreshDrawingForCurrentVideoTime() }
        }
        .onChange(of: videoModel.currentTime) { _, _ in
            // Covers "was ALREADY paused, then dragged the slider" for the drawing preview (see
            // `PlaybackView`'s matching handler for the full reasoning), and also keeps the
            // skeleton preview in sync with wherever the scrubber lands.
            if !videoModel.isPlaying {
                refreshDrawingForCurrentVideoTime()
            }
            refreshSkeletonPreviewIfNeeded()
        }
        .onChange(of: drawingState.strokes) { _, newStrokes in
            drawingEngine.saveDrawing(newStrokes, atVideoTime: currentDrawingVideoTime)
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

    // MARK: - Header

    private var headerBar: some View {
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
    }

    // MARK: - Video area: player (or skeleton preview), drawing overlay, status messages

    private var videoArea: some View {
        ZStack {
            // Skeleton preview REPLACES the live player (rather than overlaying on top of it)
            // while active — both the still frame and the projected points come from the exact
            // same extracted `CGImage`, so they're guaranteed pixel-aligned.
            if isPreviewingSkeleton, !videoModel.isPlaying, let skeletonPreview {
                SkeletonImageOverlayView(
                    cgImage: skeletonPreview.image,
                    points: skeletonPreview.points,
                    deviceOrientation: recordingDeviceOrientation
                )
            } else {
                VideoPlayer(player: videoModel.player)
            }

            if isPreviewingSkeleton, !videoModel.isPlaying, isLoadingSkeletonPreview {
                ProgressView("Detecting pose…")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if isPreviewingSkeleton, !videoModel.isPlaying, let skeletonPreviewErrorMessage {
                Text(skeletonPreviewErrorMessage)
                    .font(.caption)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if isPreviewingSkeleton, !videoModel.isPlaying, let skeletonPreview, skeletonPreview.points.isEmpty, !isLoadingSkeletonPreview {
                VStack {
                    Spacer()
                    Text("No person detected in this frame.")
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 8)
                }
            }

            if isDrawingModeOn {
                AnnotationComponent(annotationState: drawingState)
                if !videoModel.isPlaying {
                    VStack {
                        Spacer()
                        AnnotationToolbar(state: drawingState)
                            .padding(.bottom, 12)
                    }
                }
            } else if !isPreviewingSkeleton, !videoModel.isPlaying, !drawingState.strokes.isEmpty {
                // Auto-preview — see `PlaybackView.videoArea`'s doc comment for the full
                // reasoning. Skipped while the skeleton preview is showing, since that view
                // already replaces the video player entirely (see the branch above).
                AnnotationComponent(annotationState: drawingState, isInteractive: false)
            }
        }
    }

    // MARK: - Controls area: marker row, scrubber, buttons, reconstruction action

    private var controlsArea: some View {
        VStack(spacing: 12) {
            videoMarkerList
            videoScrubber
            playbackButtonsRow
            if !videoModel.isPlaying {
                reconstructionAction
            }
        }
        .padding()
    }

    private var videoScrubber: some View {
        Slider(
            value: Binding(
                get: { videoModel.currentTime },
                set: { newTime in videoModel.seek(to: newTime) }
            ),
            in: 0...max(videoModel.duration, 0.01),
            onEditingChanged: { isDragging in
                if isDragging { videoModel.pause() }
            }
        )
    }

    private var playbackButtonsRow: some View {
        HStack {
            Text(videoModel.isPlaying ? "Playing" : "Paused")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if !videoModel.isPlaying {
                toggleSkeletonPreviewButton
                toggleDrawingModeButton
            }
            playPauseButton
        }
    }

    private var toggleSkeletonPreviewButton: some View {
        Button {
            isPreviewingSkeleton.toggle()
            if isPreviewingSkeleton { refreshSkeletonPreviewIfNeeded() }
        } label: {
            Label("Preview Skeleton", systemImage: "figure.walk")
        }
        .buttonStyle(.bordered)
        .tint(isPreviewingSkeleton ? .green : nil)
        .font(.footnote)
    }

    private var toggleDrawingModeButton: some View {
        Button {
            isDrawingModeOn.toggle()
        } label: {
            Label("Annotate", systemImage: "pencil.tip")
        }
        .buttonStyle(.bordered)
        .tint(isDrawingModeOn ? .orange : nil)
        .font(.footnote)
    }

    private var playPauseButton: some View {
        Button(videoModel.isPlaying ? "Pause" : "Play") {
            videoModel.isPlaying ? videoModel.pause() : videoModel.play()
        }
    }

    /// Shows "View 3D Reconstruction" (+ delete) if this exact moment already has a saved 3D
    /// pose, an in-progress spinner while one's being generated, or "Estimate 3D View" otherwise.
    @ViewBuilder
    private var reconstructionAction: some View {
        if let nearbyEntry = reviewEngine.reconstruction(nearVideoTime: videoModel.currentTime) {
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
                // opening the full 3D view first.
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
                        reviewEngine.deleteReconstruction(pendingDeleteEntry)
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
                Button(action: generateEstimate) {
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
                if let estimateErrorMessage {
                    Text(estimateErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// Row of tappable dots along the scrubber — see `PlaybackView.videoMarkerList`'s doc
    /// comment for the full reasoning; same icon/color scheme here.
    private var videoMarkerList: some View {
        let moments = drawingEngine.getVideoMarkerList()
        return Group {
            if !moments.isEmpty, videoModel.duration > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        ForEach(moments) { moment in
                            saveVideoMarkerButton(for: moment, trackWidth: geometry.size.width)
                        }
                    }
                }
                .frame(height: 26)
            }
        }
    }

    private func saveVideoMarkerButton(for videoMarkerModel: VideoMarkerModel, trackWidth: CGFloat) -> some View {
        let positionFraction = min(max(videoMarkerModel.videoTimeInSeconds / videoModel.duration, 0), 1)
        return Button {
            goToVideoMarker(videoMarkerModel)
        } label: {
            Image(systemName: videoMarkerModel.has3DPose ? "cube.fill" : "pencil.tip.crop.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(markerColor(for: videoMarkerModel), in: Circle())
        }
        .offset(x: trackWidth * positionFraction - 13)
    }

    private func markerColor(for videoMarkerModel: VideoMarkerModel) -> Color {
        if videoMarkerModel.has3DPose {
            return videoMarkerModel.is3DPoseApproximate ? .orange : .teal
        }
        return .orange
    }

    // MARK: - Actions
    // Functions a redesigned View's buttons/gestures should call.

    /// Call whenever the video pauses, or the scrubber moves while already paused, so the
    /// drawing on screen always matches the current position.
    private func refreshDrawingForCurrentVideoTime() {
        currentDrawingVideoTime = videoModel.currentTime
        drawingState.load(strokes: drawingEngine.findDrawing(nearVideoTime: videoModel.currentTime))
    }

    /// Call when the coach taps a marker on the scrubber. Seeks there, shows whatever drawing
    /// belongs to that exact moment, and — if this moment has a saved 3D pose — opens it directly.
    private func goToVideoMarker(_ videoMarkerModel: VideoMarkerModel) {
        videoModel.seek(to: videoMarkerModel.videoTimeInSeconds)
        currentDrawingVideoTime = videoMarkerModel.videoTimeInSeconds
        drawingState.load(strokes: drawingEngine.findDrawing(nearVideoTime: videoMarkerModel.videoTimeInSeconds))
        if videoMarkerModel.has3DPose, let entry = session.reconstructions.first(where: { $0.id == videoMarkerModel.id }) {
            reviewingEntry = entry
        }
    }

    /// Pulls the current paused frame out of the saved video and runs Vision on it fresh to build
    /// a real, saved 3D pose estimate. Delegates the actual work to `reviewEngine`.
    private func generateEstimate() {
        isGeneratingEstimate = true
        estimateErrorMessage = nil
        reviewEngine.generateEstimate(
            videoURL: videoURL,
            atVideoTime: videoModel.currentTime,
            wallTextureReference: wallTextureReference,
            deviceOrientation: recordingDeviceOrientation
        ) { result in
            isGeneratingEstimate = false
            switch result {
            case .success(let entry):
                // Not surfaced as `estimateErrorMessage` — setting `reviewingEntry` immediately
                // presents `SavedReconstructionReviewView`, so an error message here would never
                // actually be seen. That's fine even for a wall-only (no-climber) entry — the
                // wall-only view itself is the useful result, not an error state.
                reviewingEntry = entry
            case .failure:
                estimateErrorMessage = "Couldn't read a frame from the video at this moment."
            }
        }
    }

    /// Refreshes the "Preview Skeleton" overlay for the current paused position. Skips a
    /// redundant re-detection if the preview already showing is close enough (in video time) to
    /// count as "this exact moment" — see `SessionReviewEngine.skeletonPreviewRefreshThresholdSeconds`.
    private func refreshSkeletonPreviewIfNeeded() {
        guard isPreviewingSkeleton, !videoModel.isPlaying else { return }
        let timestamp = videoModel.currentTime
        if let skeletonPreview, abs(skeletonPreview.videoTimeInSeconds - timestamp) < SessionReviewEngine.skeletonPreviewRefreshThresholdSeconds {
            return
        }
        guard let wallTextureReference else {
            skeletonPreviewErrorMessage = "No wall scan camera data saved for this session — can't place the skeleton preview."
            skeletonPreview = nil
            return
        }
        isLoadingSkeletonPreview = true
        skeletonPreviewErrorMessage = nil
        reviewEngine.generateSkeletonPreview(
            videoURL: videoURL,
            atVideoTime: timestamp,
            wallTextureReference: wallTextureReference,
            deviceOrientation: recordingDeviceOrientation
        ) { result in
            isLoadingSkeletonPreview = false
            switch result {
            case .success(let preview):
                skeletonPreview = preview
            case .failure(let error):
                skeletonPreviewErrorMessage = error.message
                skeletonPreview = nil
            }
        }
    }
}

// `SavedReconstructionReviewView` (the fullScreenCover destination that renders a single saved
// `ReconstructionEntry`) lives in Features/Library/Pages/SavedReconstructionReviewView.swift —
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

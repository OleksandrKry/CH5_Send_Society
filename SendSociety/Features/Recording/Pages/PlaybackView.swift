import SwiftUI
import AVKit

/// Video review screen shown after recording stops. Plays the clip, lets the coach draw on a
/// paused frame, and shows tappable markers for every moment that already has a saved drawing
/// and/or a saved 3D pose.
///
/// THIS FILE IS UI ONLY. It never searches saved annotations/reconstructions itself and never
/// does timestamp-matching math — it asks `PlaybackEngine` (see that file) for answers, and asks
/// `videoModel` (see `PlaybackModel.swift`) to actually play/pause/seek the video. If you're
/// redesigning this screen's look, this is the only file you should need to touch — the "brain"
/// underneath (`PlaybackEngine`, `PlaybackModel`) stays the same no matter what the buttons look
/// like.
struct PlaybackView: View {
    // MARK: - Given to this screen from outside

    let videoURL: URL
    let frameStore: RecordedFrameStore
    /// nil until a `RecordingSession` exists for this recording — drawings/markers are simply
    /// unavailable until then, rather than erroring.
    let session: RecordingSession?
    let sessionStore: SessionStore?
    /// Called when the coach wants to jump into the 3D view for a specific video moment.
    let onGenerate: (URL, RecordedFrameStore, TimeInterval) -> Void

    // MARK: - The "brains" this screen talks to

    /// Plays/pauses/seeks the video. Owns `player`, `currentTime`, `duration`, `isPlaying`.
    @StateObject private var videoModel: PlaybackModel
    /// Holds whatever drawing is CURRENTLY on screen (the strokes being shown or actively drawn).
    @StateObject private var drawingState = AnnotationState()
    /// Finds/saves drawings by video timestamp, and builds the scrubber's marker list. Plain
    /// Swift, no SwiftUI — see `PlaybackEngine.swift`.
    private let engine: PlaybackEngine

    // MARK: - Plain on-screen state (just "what's toggled," no logic)

    /// True while the coach has drawing mode turned on (the pencil/line/angle toolbar showing).
    @State private var isDrawingModeOn = false
    /// The video timestamp `drawingState` currently belongs to — so if the coach draws something,
    /// it gets saved under the moment it was actually drawn at, not wherever the scrubber has
    /// since moved to.
    @State private var currentDrawingVideoTime: Double = 0

    init(url: URL, frameStore: RecordedFrameStore, session: RecordingSession?, sessionStore: SessionStore?, onGenerate: @escaping (URL, RecordedFrameStore, TimeInterval) -> Void) {
        self.videoURL = url
        self.frameStore = frameStore
        self.session = session
        self.sessionStore = sessionStore
        self.onGenerate = onGenerate
        _videoModel = StateObject(wrappedValue: PlaybackModel(url: url))
        engine = PlaybackEngine(session: session, sessionStore: sessionStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            controlsArea
        }
        .onAppear(perform: refreshDrawingForCurrentVideoTime)
        .onChange(of: videoModel.isPlaying) { _, isPlaying in
            // Covers "was playing, tapped Pause."
            if !isPlaying {
                refreshDrawingForCurrentVideoTime()
            }
        }
        .onChange(of: videoModel.currentTime) { _, _ in
            // Covers "was ALREADY paused, then dragged the slider" — `isPlaying` never toggles
            // in that case, so the check above alone would leave a stale drawing on screen no
            // matter where the scrubber moves to.
            if !videoModel.isPlaying {
                refreshDrawingForCurrentVideoTime()
            }
        }
        .onChange(of: drawingState.strokes) { _, newStrokes in
            engine.saveDrawing(newStrokes, atVideoTime: currentDrawingVideoTime)
        }
    }

    // MARK: - Video area: the player itself, plus whatever drawing overlay is showing

    private var videoArea: some View {
        ZStack {
            VideoPlayer(player: videoModel.player)
                .onAppear { videoModel.play() }

            if isDrawingModeOn {
                AnnotationComponent(annotationState: drawingState)
                if !videoModel.isPlaying {
                    VStack {
                        Spacer()
                        AnnotationToolbar(state: drawingState)
                            .padding(.bottom, 12)
                    }
                }
            } else if !videoModel.isPlaying, !drawingState.strokes.isEmpty {
                // Auto-preview: a saved drawing near the current position shows up on its own
                // once the video pauses — the coach shouldn't need to tap "Annotate" just to SEE
                // markup that's already there. `isInteractive: false` makes this read-only so it
                // doesn't block taps meant for Play, Generate, or a marker underneath.
                AnnotationComponent(annotationState: drawingState, isInteractive: false)
            }
        }
    }

    // MARK: - Controls area: marker row, scrubber, buttons

    private var controlsArea: some View {
        VStack(spacing: 12) {
            videoMarkerList
            videoScrubber
            playbackButtonsRow
            if !videoModel.isPlaying {
                generate3DButton
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
            if !videoModel.isPlaying, session != nil {
                toggleDrawingModeButton
            }
            playPauseButton
        }
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

    private var generate3DButton: some View {
        Button {
            onGenerate(videoURL, frameStore, videoModel.currentTime)
        } label: {
            Text("Generate 3D View")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
    }

    /// Row of tappable dots along the scrubber — one per saved moment (drawing and/or 3D pose).
    /// Cube icon/teal = has a 3D pose (orange tint if it was only estimated, not measured live).
    /// Pencil icon/orange = drawing only. Tapping a marker jumps straight to that moment.
    private var videoMarkerList: some View {
        let moments = engine.getVideoMarkerList()
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
    // These are the functions a redesigned View's buttons/gestures should call. Nothing below
    // this line touches SwiftUI layout — it only updates state and asks `engine`/`videoModel`
    // to do the actual work.

    /// Call whenever the video pauses, or the scrubber moves while already paused, so the
    /// drawing on screen always matches the current position (within `PlaybackEngine`'s ±1s
    /// matching window).
    private func refreshDrawingForCurrentVideoTime() {
        currentDrawingVideoTime = videoModel.currentTime
        drawingState.load(strokes: engine.findDrawing(nearVideoTime: videoModel.currentTime))
    }

    /// Call when the coach taps a marker on the scrubber. Seeks the video there, shows whatever
    /// drawing belongs to that exact moment, and — if this moment has a saved 3D pose — jumps
    /// straight into the 3D view for it via `onGenerate`.
    private func goToVideoMarker(_ videoMarkerModel: VideoMarkerModel) {
        videoModel.seek(to: videoMarkerModel.videoTimeInSeconds)
        currentDrawingVideoTime = videoMarkerModel.videoTimeInSeconds
        drawingState.load(strokes: engine.findDrawing(nearVideoTime: videoMarkerModel.videoTimeInSeconds))
        if videoMarkerModel.has3DPose {
            onGenerate(videoURL, frameStore, videoMarkerModel.videoTimeInSeconds)
        }
    }
}

// `PlaybackModel` (the AVPlayer wrapper backing this screen's scrubber) lives in
// Features/Shared/Components/PlaybackModel.swift — it's reused as-is by `SessionReviewView`
// (Library), so it lives in Shared rather than under this feature.
//
// `PlaybackEngine` (the drawing/marker "brain" for this screen) lives right next to this file,
// in PlaybackEngine.swift.

// Preview note: the URL below doesn't point to a real video, so the player area will show black/
// an error instead of actual footage — everything else (scrubber, buttons, Annotate toggle) still
// renders normally, which is enough to check this screen's layout without a real recording.
#Preview {
    PlaybackView(
        url: FileManager.default.temporaryDirectory.appendingPathComponent("preview.mp4"),
        frameStore: RecordedFrameStore(),
        session: nil,
        sessionStore: nil
    ) { _, _, _ in }
}

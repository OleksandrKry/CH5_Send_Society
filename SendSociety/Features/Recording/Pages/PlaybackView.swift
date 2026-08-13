import SwiftUI
import AVKit

/// Standard video player + scrubber shown after Step 3 recording stops. When paused, shows the
/// "Generate" button that hands off to Step 4, and (feedback item #1) an "Annotate" toggle for
/// marking up the paused frame in 2D — the SAME `AnnotationOverlay`/`AnnotationToolbar` Step 4
/// uses for its 3D view, reused here for plain video-frame markup. Also shows tick marks on the
/// scrubber for moments that already have a saved 3D reconstruction (feedback item #2), so
/// revisiting a session makes it obvious which frames are worth re-opening in Step 4.
struct PlaybackView: View {
    let url: URL
    let frameStore: RecordedFrameStore
    /// nil until a `RecordingSession` exists for this recording (see
    /// `ContentView.createSessionIfNeeded`) — annotation/markers are simply unavailable until
    /// then, rather than erroring.
    let session: RecordingSession?
    let sessionStore: SessionStore?
    let onGenerate: (URL, RecordedFrameStore, TimeInterval) -> Void

    @StateObject private var model: PlaybackModel
    @StateObject private var annotationState = AnnotationState()
    @State private var isAnnotating = false
    /// The timestamp bucket `annotationState` currently reflects — so a strokes change is only
    /// ever saved under the timestamp it was actually drawn at, not wherever the scrubber has
    /// since moved to (playback continues to advance `model.currentTime` while the coach is still
    /// mid-stroke on an already-paused frame... actually strokes only change while paused, but the
    /// save should still target the moment annotation began, not a since-drifted currentTime).
    @State private var annotatedTimestamp: Double = 0

    init(url: URL, frameStore: RecordedFrameStore, session: RecordingSession?, sessionStore: SessionStore?, onGenerate: @escaping (URL, RecordedFrameStore, TimeInterval) -> Void) {
        self.url = url
        self.frameStore = frameStore
        self.session = session
        self.sessionStore = sessionStore
        self.onGenerate = onGenerate
        _model = StateObject(wrappedValue: PlaybackModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VideoPlayer(player: model.player)
                    .onAppear { model.play() }
                if isAnnotating {
                    AnnotationOverlay(state: annotationState)
                    if !model.isPlaying {
                        VStack {
                            Spacer()
                            AnnotationToolbar(state: annotationState)
                                .padding(.bottom, 12)
                        }
                    }
                } else if !model.isPlaying, !annotationState.strokes.isEmpty {
                    // Auto-preview: a saved annotation within ±1s of wherever the scrubber landed
                    // (see `loadAnnotationsForCurrentTime()`) shows up on its own the moment
                    // playback pauses nearby — the coach shouldn't have to remember to tap
                    // "Annotate" just to SEE markup that's already there. `isInteractive: false`
                    // keeps this read-only so it doesn't steal the tap that's meant for the Play
                    // button, the Generate button, or a marker underneath.
                    AnnotationOverlay(state: annotationState, isInteractive: false)
                }
            }
            .allowsHitTesting(true)

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
                    if !model.isPlaying, session != nil {
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
                    Button {
                        onGenerate(url, frameStore, model.currentTime)
                    } label: {
                        Text("Generate 3D View")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding()
        }
        .onChange(of: model.isPlaying) { _, isPlaying in
            // Reload whatever's saved for the new paused position (or clear, if nothing's saved
            // there) every time playback pauses/a scrub ends — this is the one point where
            // "current timestamp bucket" is stable enough to key annotations off of.
            if !isPlaying {
                loadAnnotationsForCurrentTime()
            }
        }
        .onAppear {
            loadAnnotationsForCurrentTime()
        }
        .onChange(of: annotationState.strokes) { _, newValue in
            guard let session, let sessionStore else { return }
            session.setVideoAnnotation(timestampSeconds: annotatedTimestamp, strokes: newValue)
            sessionStore.save()
        }
    }

    private func loadAnnotationsForCurrentTime() {
        loadAnnotations(at: model.currentTime)
    }

    /// Loads whatever's saved within ±1s of `timestamp` — the "by default the saved annotation
    /// will appear if user move the movie slider +- 1 second in that time frame" window, per the
    /// coach's own request. Takes an explicit `timestamp` (rather than always reading
    /// `model.currentTime` itself) so `jump(to:)` can load the RIGHT annotation for the marker it
    /// just seeked to without waiting on `model.currentTime` to catch up — `PlaybackModel`'s
    /// `currentTime` only updates via its periodic (~30x/sec) time observer once the underlying
    /// `AVPlayer` seek actually completes, which is asynchronous and hasn't necessarily happened
    /// yet in the same run-loop turn as the tap that triggered it.
    private func loadAnnotations(at timestamp: Double) {
        annotatedTimestamp = timestamp
        guard let session else {
            annotationState.load(strokes: [])
            return
        }
        let nearest = session.videoAnnotations.first { abs($0.timestampSeconds - timestamp) <= 1.0 }
        annotationState.load(strokes: nearest?.strokes ?? [])
    }

    /// One tappable moment on the scrubber's marker track — either a saved 3D reconstruction, a
    /// saved annotation, or (common case) both at once, merged into a single marker per
    /// `savedMoments` so the coach isn't looking at two overlapping dots for what's really one
    /// moment they marked up.
    private struct SavedMoment: Identifiable {
        let id: UUID
        let timestampSeconds: Double
        let hasAnnotation: Bool
        let hasReconstruction: Bool
        let isApproximateReconstruction: Bool
    }

    /// Merges `session.reconstructions` and `session.videoAnnotations` into one marker list —
    /// an annotation within 0.5s of a reconstruction is folded into that reconstruction's marker
    /// (the reconstruction is the richer artifact and anchors the timestamp shown); anything else
    /// becomes its own annotation-only marker. Sorted by time purely so marker ordering on screen
    /// is stable/predictable.
    private var savedMoments: [SavedMoment] {
        guard let session else { return [] }
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

    /// Seeks straight to `moment`'s timestamp and shows whatever it has: a reconstruction jumps
    /// straight into Step 4's 3D view via `onGenerate` (which loads the EXACT saved entry rather
    /// than re-running Vision — see `ContentView.ReconstructionHost.generate()`'s near-enough-saved
    /// check), while an annotation-only moment relies on the auto-preview above to show its strokes
    /// once the seek lands (paused, since `PlaybackModel.seek(to:)` always pauses first).
    private func jump(to moment: SavedMoment) {
        model.seek(to: moment.timestampSeconds)
        loadAnnotations(at: moment.timestampSeconds)
        if moment.hasReconstruction {
            onGenerate(url, frameStore, moment.timestampSeconds)
        }
    }

    /// Tappable markers along the scrubber's track for every saved moment (3D reconstruction
    /// and/or annotation) — larger and directly tappable (feedback: "make it larger and
    /// clickable... when clicking that circle, it show go to the specific time frame directly"),
    /// unlike the old plain 6pt display-only dots. Cube icon/teal = has a 3D reconstruction
    /// (orange tint if it's an approximate/estimated one), pencil icon/orange = annotation only.
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

// `PlaybackModel` (the AVPlayer wrapper backing this screen's scrubber) has moved to
// Features/Shared/Components/PlaybackModel.swift — it's reused as-is by `SessionReviewView`
// (Library), so it lives in Shared rather than under this feature.

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

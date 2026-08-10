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
                }
            }
            .allowsHitTesting(true)

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
        annotatedTimestamp = model.currentTime
        guard let session else {
            annotationState.load(strokes: [])
            return
        }
        let nearest = session.videoAnnotations.first { abs($0.timestampSeconds - model.currentTime) <= 0.3 }
        annotationState.load(strokes: nearest?.strokes ?? [])
    }

    /// Small dots along the scrubber's track marking timestamps that already have a saved 3D
    /// reconstruction — approximate positioning via `GeometryReader` (the same 0...duration range
    /// the `Slider` above uses), not pixel-perfect alignment with the Slider's own thumb track,
    /// but close enough to clearly communicate "generated moments are around here."
    @ViewBuilder
    private var reconstructionMarkerTrack: some View {
        if let session, !session.reconstructions.isEmpty, model.duration > 0 {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    ForEach(session.reconstructions) { entry in
                        let fraction = min(max(entry.timestampSeconds / model.duration, 0), 1)
                        Circle()
                            .fill(Color.teal)
                            .frame(width: 6, height: 6)
                            .offset(x: geometry.size.width * fraction - 3)
                    }
                }
            }
            .frame(height: 8)
        }
    }
}

// `PlaybackModel` (the AVPlayer wrapper backing this screen's scrubber) has moved to
// Features/Shared/Components/PlaybackModel.swift — it's reused as-is by `SessionReviewView`
// (Library), so it lives in Shared rather than under this feature.

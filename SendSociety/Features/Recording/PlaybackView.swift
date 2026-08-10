import SwiftUI
import AVKit
import Combine

/// Standard video player + scrubber shown after Step 3 recording stops. When paused, shows the
/// "Generate" button that hands off to Step 4.
struct PlaybackView: View {
    let url: URL
    let frameStore: RecordedFrameStore
    let onGenerate: (URL, RecordedFrameStore, TimeInterval) -> Void

    @StateObject private var model: PlaybackModel

    init(url: URL, frameStore: RecordedFrameStore, onGenerate: @escaping (URL, RecordedFrameStore, TimeInterval) -> Void) {
        self.url = url
        self.frameStore = frameStore
        self.onGenerate = onGenerate
        _model = StateObject(wrappedValue: PlaybackModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: model.player)
                .onAppear { model.play() }

            VStack(spacing: 12) {
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
    }
}

/// Thin AVPlayer wrapper exposing playback state as @Published so SwiftUI can bind a scrubber to
/// it. Kept separate from the view so time-observer bookkeeping isn't tangled in view code.
final class PlaybackModel: ObservableObject {
    let player: AVPlayer
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isPlaying = false

    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            self?.currentTime = time.seconds
        }

        item.publisher(for: \.duration)
            .sink { [weak self] duration in
                guard duration.isNumeric else { return }
                self?.duration = duration.seconds
            }
            .store(in: &cancellables)
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        pause()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }
}

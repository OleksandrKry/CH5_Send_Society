import AVKit
import Combine
import Foundation

/// Thin AVPlayer wrapper exposing playback state as @Published so SwiftUI can bind a scrubber to
/// it. Kept separate from any one screen's view code so time-observer bookkeeping isn't tangled in
/// it — shared as-is between `PlaybackView` (Step 3's just-recorded clip) and `SessionReviewView`
/// (revisiting a saved session's video), which is why this lives in Shared rather than under either
/// feature.
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

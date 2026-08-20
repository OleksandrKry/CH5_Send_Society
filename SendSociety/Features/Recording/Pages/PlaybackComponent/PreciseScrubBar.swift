//
//  PreciseScrubBar.swift
//  SendSociety
//

import SwiftUI

/// A dense, ±`halfWindowSeconds`-wide thumbnail scrubber for landing on one exact video moment.
/// Hidden by default — `PlaybackPanel`'s right-side toggle button inserts/removes this view from
/// the layout entirely (an `if isPreciseScrubberVisible { PreciseScrubBar(...) }`, not a view that's
/// always present just switching content). The window is only (re)centered on `currentTime` when it
/// first appears, or when `currentTime` moves outside it from some OTHER control (e.g. the main
/// `Slider`) while this bar isn't being touched — deliberately NOT after every drag release: doing
/// that would recompute the window as an exact ±1s straddle of wherever you just released, which
/// mathematically always puts the playhead back at the dead center of the bar — i.e. the "snaps back
/// to the middle" bug. Leaving the window alone on release keeps the playhead exactly where you left
/// it.
struct PreciseScrubBar: View {
    @Binding var currentTime: Double
    let duration: Double
    let videoURL: URL
    @Binding var isPlaying: Bool

    @State private var thumbnails: [PreciseThumbnail] = []
    @State private var window: ClosedRange<Double>?
    @State private var isDragging = false

    private let stripHeight: CGFloat = 44
    private let thumbnailCount = 24
    /// Half-width, in seconds, of the visible/draggable window — i.e. spans
    /// `currentTime - halfWindowSeconds ... currentTime + halfWindowSeconds`.
    private let halfWindowSeconds: Double = 1

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.primaryLightLessOpacity)

                HStack(spacing: 1) {
                    ForEach(thumbnails) { thumbnail in
                        Image(decorative: thumbnail.image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width / CGFloat(max(thumbnails.count, 1)))
                            .clipped()
                    }
                }
                .frame(width: geometry.size.width, height: stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                RoundedRectangle(cornerRadius: 10)
                    .stroke(.primaryBlue, lineWidth: 2)

                playhead(trackWidth: geometry.size.width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isPlaying = false
                        isDragging = true
                        if window == nil {
                            recenterWindow()
                        }
                        currentTime = time(for: value.location.x, trackWidth: geometry.size.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: stripHeight)
        .onAppear {
            recenterWindow()
        }
        .onChange(of: currentTime) { _, newValue in
            guard !isDragging, let window else { return }
            if newValue < window.lowerBound || newValue > window.upperBound {
                recenterWindow()
            }
        }
        .task(id: window) {
            await loadThumbnailsIfNeeded()
        }
    }

    private func recenterWindow() {
        let lower = max(0, currentTime - halfWindowSeconds)
        let upper = min(duration, currentTime + halfWindowSeconds)
        window = lower < upper ? lower...upper : nil
    }

    private func time(for x: CGFloat, trackWidth: CGFloat) -> Double {
        guard trackWidth > 0, let window else { return currentTime }
        let fraction = Double(min(max(x / trackWidth, 0), 1))
        return window.lowerBound + fraction * (window.upperBound - window.lowerBound)
    }

    private func playhead(trackWidth: CGFloat) -> some View {
        let progress: Double
        if let window, window.upperBound > window.lowerBound {
            progress = min(max((currentTime - window.lowerBound) / (window.upperBound - window.lowerBound), 0.0), 1.0)
        } else {
            progress = 0
        }
        let xOffset: CGFloat = trackWidth * CGFloat(progress) - 1.0
        return RoundedRectangle(cornerRadius: 1)
            .fill(.primaryBlue)
            .frame(width: 2, height: stripHeight)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .offset(x: xOffset)
    }

    private func loadThumbnailsIfNeeded() async {
        guard let window else {
            thumbnails = []
            return
        }
        let extracted = await VideoFrameExtractor.extractThumbnailStrip(
            from: videoURL,
            range: window,
            count: thumbnailCount
        )
        guard !extracted.isEmpty else { return }
        thumbnails = extracted.map { PreciseThumbnail(time: $0.time, image: $0.image) }
    }
}

private struct PreciseThumbnail: Identifiable {
    let time: Double
    let image: CGImage
    var id: Double { time }
}

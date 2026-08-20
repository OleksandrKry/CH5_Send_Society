//
//  PlaybackPanel.swift
//  SendSociety
//
//  Created by Alan Brian Frederick on 12/08/26.
//

import SwiftUI

struct PlaybackPanel: View {
    
    // MARK: - Playback State
    
    @Binding var currentTime: Double
    let duration: Double
    let videoURL: URL

    @Binding var isPlaying: Bool
    @Binding var playbackRate: Double
    
    // MARK: - initialize VideoMarker data
    
    let videoMarkerList: [VideoMarkerModel]
    let onVideoMarkerClick: (VideoMarkerModel) -> Void

    // MARK: - Precise scrub bar toggle

    @State private var isPreciseScrubberVisible = false

    // MARK: - Playback Speeds
    
    private let playbackSpeeds: [Double] = [
        0.25,
        0.5,
        0.75,
        1.0,
        1.25,
        1.5,
        2.0
    ]
    
    var body: some View {
        VStack(spacing: 24) {
            
            // MARK: Timeline
            
            HStack(spacing: 12) {
                
                Text(formatTime(currentTime))
                    .font(.body)
                    .foregroundStyle(.primaryDark)
                    .monospacedDigit()
                
                VStack(spacing: 4) {
                    if !videoMarkerList.isEmpty, duration > 0 {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                ForEach(videoMarkerList) { videoMarker in
                                    videoMarkerButton(for: videoMarker, trackWidth: geometry.size.width)
                                }
                            }
                        }
                        .frame(height: 16)
                    }

                    if isPreciseScrubberVisible {
                        PreciseScrubBar(
                            currentTime: $currentTime,
                            duration: duration,
                            videoURL: videoURL,
                            isPlaying: $isPlaying
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    ZStack {
                        // The native Slider's own track is thin and low-contrast against the
                        // panel's `.ultraThinMaterial` background — this capsule gives it a solid
                        // base to sit on so it doesn't disappear over busy/light video frames.
                        Capsule()
                            .fill(.primaryLightLessOpacity)
                            .frame(height: 6)

                        Slider(
                            value: $currentTime,
                            in: 0...max(duration, 1),
                            onEditingChanged: { isEditing in
                                if isEditing {
                                    isPlaying = false
                                    // The precise scrub bar's ±1s window goes stale the moment the
                                    // coarse Slider jumps `currentTime` somewhere else — hide it
                                    // rather than let it show a window around the OLD position.
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isPreciseScrubberVisible = false
                                    }
                                }
                            }
                        )
                        .tint(.primaryBlue)
                    }
                }
                
                Text(formatTime(duration))
                    .font(.body)
                    .foregroundStyle(.primaryDark)
                    .monospacedDigit()
            }
            
            // MARK: Playback Buttons
            
            HStack {
                
                // MARK: Playback Speed
                
                Menu {
                    ForEach(playbackSpeeds, id: \.self) { speed in
                        Button {
                            playbackRate = speed
                        } label: {
                            HStack {
                                Text(speedText(speed))
                                
                                if playbackRate == speed {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(speedText(playbackRate))
                        .font(.body)
                        .foregroundStyle(.primaryDark)
                        .frame(width: 48, height: 48)
                        .background(.primaryLightLessOpacity)
                        .clipShape(Circle())
                        .shadow(
                            color: .black.opacity(0.15),
                            radius: 4,
                            y: 2
                        )
                }
                
                Spacer()
                
                // MARK: Previous Frame
                
//                Button {
//                    // Previous frame action
//                    currentTime = max(currentTime - 5, 0)
//                } label: {
//                    Image(systemName: "backward.frame")
//                        .font(.system(size: 24))
//                        .foregroundStyle(.primaryDark)
//                        .frame(width: 48, height: 48)
//                        .background(.primaryLightLessOpacity)
//                        .clipShape(Circle())
//                        .shadow(
//                            color: .black.opacity(0.15),
//                            radius: 4,
//                            y: 2
//                        )
//                }
                
                // MARK: Play / Pause
                
                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause" : "play")
                        .font(.system(size: 28))
                        .foregroundStyle(.primaryDark)
                        .frame(width: 56, height: 56)
                        .background(.primaryLightLessOpacity)
                        .clipShape(Circle())
                        .shadow(
                            color: .black.opacity(0.15),
                            radius: 4,
                            y: 2
                        )
                        .padding(.horizontal, 24)
                }
                
                // MARK: Next Frame
                
//                Button {
//                    // Next frame action
//                    currentTime = min(currentTime + 5, duration)
//                } label: {
//                    Image(systemName: "forward.frame")
//                        .font(.system(size: 24))
//                        .foregroundStyle(.primaryDark)
//                        .frame(width: 48, height: 48)
//                        .background(.primaryLightLessOpacity)
//                        .clipShape(Circle())
//                        .shadow(
//                            color: .black.opacity(0.15),
//                            radius: 4,
//                            y: 2
//                        )
//                }
                
                Spacer()
                
                // MARK: Precise Scrub Bar Toggle

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPreciseScrubberVisible.toggle()
                    }
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: 24))
                        .foregroundStyle(isPreciseScrubberVisible ? .white : .primaryDark)
                        .frame(width: 48, height: 48)
                        .background(isPreciseScrubberVisible ? AnyShapeStyle(.primaryBlue) : AnyShapeStyle(.primaryLightLessOpacity))
                        .clipShape(Circle())
                        .shadow(
                            color: .black.opacity(0.15),
                            radius: 4,
                            y: 2
                        )
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background(.ultraThinMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 24)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(
                    .white.opacity(0.8),
                    lineWidth: 1
                )
        }
        .shadow(
            color: .black.opacity(0.12),
            radius: 8,
            y: 3
        )
    }
    
    // MARK: - Playback Speed Text
    
    private func speedText(_ speed: Double) -> String {
        if speed.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(speed))x"
        } else {
            return "\(speed)x"
        }
    }
    
    // MARK: - Time Formatting
    
    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        
        return String(
            format: "%d:%02d",
            minutes,
            seconds
        )
    }
    
    private func videoMarkerButton(for videoMarkerModel: VideoMarkerModel, trackWidth: CGFloat) -> some View {
        let fraction = duration > 0 ? min(max(videoMarkerModel.videoTimeInSeconds / duration, 0), 1) : 0
        return Button {
            onVideoMarkerClick(videoMarkerModel)
        } label: {
            Image(systemName: videoMarkerModel.has3DPose ? "cube.fill" : "pencil.tip.crop.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(markerColor(for: videoMarkerModel), in: Circle())
        }
        .offset(x: trackWidth * fraction - 8)
    }

    private func markerColor(for videoMarkerModel: VideoMarkerModel) -> Color {
        if videoMarkerModel.has3DPose {
            return videoMarkerModel.is3DPoseApproximate ? .orange : .teal
        }
        return .orange
    }
}

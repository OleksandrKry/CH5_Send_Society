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
    
    @Binding var isPlaying: Bool
    @Binding var playbackRate: Double
    
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
                
                Slider(
                    value: $currentTime,
                    in: 0...max(duration, 1)
                )
                .tint(.primaryBlue)
                
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
                
                Button {
                    // Previous frame action
                } label: {
                    Image(systemName: "backward.frame")
                        .font(.system(size: 24))
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
                
                Button {
                    // Next frame action
                } label: {
                    Image(systemName: "forward.frame")
                        .font(.system(size: 24))
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
                
                // MARK: Frame / Timeline View
                
                Button {
                    // Timeline action
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: 24))
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
}

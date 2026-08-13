//
//  PlaybackOverlay.swift
//  SendSociety
//
//  Created by Alan Brian Frederick on 12/08/26.
//

import SwiftUI

struct PlaybackOverlay: View {
    
    @Binding var currentTime: Double
    let duration: Double
    
    @Binding var isPlaying: Bool
    @Binding var playbackRate: Double
    
    var body: some View {
        HStack(
            alignment: .bottom,
            spacing: 24
        ) {
            
            // MARK: Hand Tool
            
            Button {
                // Hand tool action
            } label: {
                Image(systemName: "hand.raised")
                    .font(.title)
                    .foregroundStyle(.primaryDark)
                    .frame(
                        width: 72,
                        height: 72
                    )
                    .background(
                        .primaryLightLessOpacity
                    )
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(
                                .white.opacity(0.8),
                                lineWidth: 1
                            )
                    }
                    .shadow(
                        color: .black.opacity(0.15),
                        radius: 6,
                        y: 2
                    )
            }
            .offset(y: -32)

            
            Spacer()
            
            // MARK: Playback Panel
            
            PlaybackPanel(
                currentTime: $currentTime,
                duration: duration,
                isPlaying: $isPlaying,
                playbackRate: $playbackRate
            )
            .frame(
                maxWidth: 640
            )
            
            Spacer()
            
            // MARK: 3D Button
            
            Button {
                // 3D action
            } label: {
                Text("3D")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(
                        width: 72,
                        height: 72
                    )
                    .background(.primaryBlue)
                    .clipShape(Circle())
            }
            .offset(y: -32)
        }
        .padding(.horizontal, 64)
        .padding(.bottom, 32)
    }
}



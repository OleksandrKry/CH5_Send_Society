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
    @State private var isClimbingAnnotationOpen = false
    
    var body: some View {
        HStack(
            alignment: .bottom,
            spacing: 24
        ) {
            
            // Hand Button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isClimbingAnnotationOpen.toggle()
                }
            } label: {
                Image(
                    systemName: isClimbingAnnotationOpen
                    ? "chevron.up"
                    : "hand.raised"
                )
                .font(.title)
                .foregroundStyle(.primaryDark)
                .frame(width: 72, height: 72)
                .background(.primaryLightLessOpacity)
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
            
            PlaybackPanel(
                currentTime: $currentTime,
                duration: duration,
                isPlaying: $isPlaying,
                playbackRate: $playbackRate
            )
            .frame(maxWidth: 640)
            
            Spacer()
            
            // 3D Button
            Button {
                // 3D action
            } label: {
                Text("3D")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.primaryBlue)
                    .clipShape(Circle())
            }
            .offset(y: -32)
        }
        .padding(.horizontal, 64)
        .padding(.bottom, 32)
        .overlay(alignment: .bottomLeading) {
            
            if isClimbingAnnotationOpen {
                ClimbingAnnotation()
                    .offset(
                        x: 20,
                        y: -160
                    )
                    .transition(
                        .scale(
                            scale: 0.95,
                            anchor: .bottom
                        )
                        .combined(with: .opacity)
                    )
            }
        }
    }
}


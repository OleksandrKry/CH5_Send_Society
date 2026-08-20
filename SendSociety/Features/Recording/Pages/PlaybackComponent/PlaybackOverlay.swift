//
//  PlaybackOverlay.swift
//  SendSociety
//
//  Created by Christofer Theodore on 14/08/26.
//

import SwiftUI

struct PlaybackOverlay: View {
    
    @Binding var currentTime: Double
    let duration: Double
    
    @Binding var isPlaying: Bool
    @Binding var playbackRate: Double
    
    // MARK: - initialize VideoMarker data
    
    let videoMarkerList: [VideoMarkerModel]
    let onVideoMarkerClick: (VideoMarkerModel) -> Void
    @State private var isClimbingAnnotationOpen = false
    
    let onGenerate3D: () -> Void
    
    var body: some View {
        HStack(
            alignment: .bottom,
            spacing: 24
        ) {
            
            // MARK: Hand Tool
            
//            Button {
//                // Hand tool action
//                withAnimation(.easeInOut(duration: 0.2)) {
//                    isClimbingAnnotationOpen.toggle()
//                }
//            } label: {
//                Image(systemName: "hand.raised")
//                    .font(.title)
//                    .foregroundStyle(.primaryDark)
//                    .frame(
//                        width: 72,
//                        height: 72
//                    )
//                    .background(
//                        .primaryLightLessOpacity
//                    )
//                    .clipShape(Circle())
//                    .overlay {
//                        Circle()
//                            .stroke(
//                                .white.opacity(0.8),
//                                lineWidth: 1
//                            )
//                    }
//                    .shadow(
//                        color: .black.opacity(0.15),
//                        radius: 6,
//                        y: 2
//                    )
//            }
//            .offset(y: -32)
            Button {
                // 3D action
                onGenerate3D()
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

            
            Spacer()
            
            // MARK: Playback Panel
            
            PlaybackPanel(
                currentTime: $currentTime,
                duration: duration,
                isPlaying: $isPlaying,
                playbackRate: $playbackRate,
                videoMarkerList: videoMarkerList,
                onVideoMarkerClick: onVideoMarkerClick
            )
            .frame(
                maxWidth: 640
            )
            
            Spacer()
            Spacer()
            // MARK: 3D Button
            
            
        }
        .padding(.horizontal, 64)
        .padding(.bottom, 32)
//        .overlay(alignment: .bottomLeading) {
//                    
//            if isClimbingAnnotationOpen {
//                ClimbingAnnotation()
//                    .offset(
//                        x: 20,
//                        y: -160
//                    )
//                    .transition(
//                        .scale(
//                            scale: 0.95,
//                            anchor: .bottom
//                        )
//                        .combined(with: .opacity)
//                    )
//            }
//        }
    }
}



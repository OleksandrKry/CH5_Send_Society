//
//  PlaybackDesignNew.swift
//  SendSociety
//
//  Created by Alan Brian Frederick on 12/08/26.
//

import SwiftUI

struct PlaybackDesign: View {
    
    @State private var currentTime: Double = 30
    @State private var duration: Double = 75
    @State private var isPlaying = false
    @State private var playbackRate: Double = 1
    
    var body: some View {
        NavigationStack {
            
            ZStack (alignment: .topLeading) {
                GeometryReader { proxy in
                               Image("climbingPlaceholder")
                                   .resizable()
                                   .scaledToFill()
                                   .frame(
                                       width: proxy.size.width,
                                       height: proxy.size.height
                                   )
                                   .clipped()
                           }
                            .ignoresSafeArea()

                
                ClimbInfoCard()
                    .padding(.top, 16)
                    .padding(.leading, 16)
            }
            .overlay(alignment: .topTrailing) {
                                AnnotateToolbar()
                                .padding(.top, 120)
                                .padding(.trailing, 24)
            }
            
            .overlay(alignment: .bottom) {
                           PlaybackOverlay(
                               currentTime: $currentTime,
                               duration: duration,
                               isPlaying: $isPlaying,
                               playbackRate: $playbackRate
                           )
            }
            
            .navigationTitle("Climb at Bali Boulder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                        
                // LEFT
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        // Close action
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                
                
                // RIGHT
                ToolbarItemGroup(placement: .topBarTrailing) {
                    
                    Button {
                        // Accessibility action
                    } label: {
                        Image(systemName: "figure")
                    }
                    
                    Button {
                        // More action
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    
                    Button {
                        // Share action
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

#Preview {
    PlaybackDesign()
}

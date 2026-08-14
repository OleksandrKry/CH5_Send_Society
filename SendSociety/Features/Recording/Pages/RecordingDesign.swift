//
//  RecordingDesign.swift
//  SendSociety
//
//  Created by Alan Brian Frederick on 14/08/26.
//

import SwiftUI

struct RecordingDesign: View {
    
    var body: some View {
        ZStack {
            
            // MARK: Background
            
            Color(.tertiaryDark)
                .ignoresSafeArea()
            
            // MARK: Recording Timer
            
            Text("00:00:00")
                .font(.title2)
                .monospacedDigit()
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassEffect(
                    .regular,
                    in: Capsule()
                )
                .frame(
                    maxHeight: .infinity,
                    alignment: .top
                )
                .padding(.top, 16)
            
            // MARK: Left Control
            
            HStack {
                
                Button {
                    // Person / subject action
                } label: {
                    Image(systemName: "person")
                        .font(.title3)
                        .frame(
                            width: 56,
                            height: 56
                        )
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular,
                    in: Circle()
                )
                
                Spacer()
            }
            .padding(.horizontal, 44)
            
            // MARK: Right Controls
            
            VStack(spacing: 16) {
                
                // MARK: Resolution
                
                Button {
                    // Resolution
                } label: {
                    VStack(spacing: 0) {
                        Text("HD")
                            .font(.body)
                        
                        Text("RES")
                            .font(.caption2)
                    }
                    .frame(
                        width: 56,
                        height: 56
                    )
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular,
                    in: Circle()
                )
                
                
                // MARK: Frame Rate
                
                Button {
                    // Frame rate
                } label: {
                    VStack(spacing: 0) {
                        Text("30")
                            .font(.body)
                        
                        Text("FPS")
                            .font(.caption2)
                    }
                    .frame(
                        width: 56,
                        height: 56
                    )
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular,
                    in: Circle()
                )
                
                
                // MARK: Audio
                
                Button {
                    // Audio
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title3)
                        .frame(
                            width: 56,
                            height: 56
                        )
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular,
                    in: Circle()
                )
                
                
                // MARK: Record
                
                Button {
                    // Start / stop recording
                } label: {
                    Circle()
                        .fill(.red)
                        .frame(
                            width: 64,
                            height: 64
                        )
                        .frame(
                            width: 72,
                            height: 72
                        )
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular,
                    in: Circle()
                )
                .padding(.vertical, 8)
                
                // MARK: Previous Recording
                
                Button {
                    // Open previous video
                } label: {
                    Image("climbingPlaceholder")
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: 56,
                            height: 56
                        )
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular,
                    in: Circle()
                )
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .trailing
            )
            .padding(.trailing, 48)
            
            
            // MARK: Close
            
            VStack {
                
                Spacer()
                
                HStack {
                    Spacer()
                    
                    Button("Session Done") {
                        // Close recording
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.trailing, 48)
            .padding(.bottom, 32)
        }
    }
}

#Preview {
    RecordingDesign()
}

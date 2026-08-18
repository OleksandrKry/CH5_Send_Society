//
//  ClimbingAnnotation.swift
//  SendSociety
//
//  Created by Alan Brian Frederick on 13/08/26.
//

import SwiftUI

struct ClimbingAnnotation: View {
    
    var body: some View {
        VStack(spacing: 18) {
            
            // MARK: - Body
            
            Text("Body")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primaryDark)
            
            VStack(spacing: 14) {
                
                HStack(spacing: 32) {
                    
                    bodyItem(
                        icon: "hand.raised.fill",
                        text: "Left"
                    )
                    
                    bodyItem(
                        icon: "hand.raised.fill",
                        text: "Right",
                        mirrored: true
                    )
                }
                
                HStack(spacing: 32) {
                    
                    footItem(
                        text: "Left"
                    )
                    
                    footItem(
                        text: "Right",
                        mirrored: true
                    )
                }
            }
            
            // MARK: - Holds
            
            Text("Holds")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primaryDark)
                .padding(.top, 4)
            
            VStack(spacing: 10) {
                
                holdButton("Jug")
                holdButton("Crimp")
                holdButton("Sloper")
                holdButton("Pinch")
                holdButton("Pocket")
                holdButton("Volume")
            }
            
            
            // MARK: - Movement
            
            Text("Movement")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primaryDark)
                .padding(.top, 4)
            
            VStack(spacing: 10) {
                
                holdButton("Reach")
                holdButton("Flag")
                holdButton("Cross")
                holdButton("Heel Hook")
                holdButton("Toe Hook")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .background(
            .white.opacity(0.90)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 40
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 40
            )
            .stroke(
                .white.opacity(0.85),
                lineWidth: 1
            )
        }
        .shadow(
            color: .black.opacity(0.15),
            radius: 8,
            y: 3
        )
    }
}


// MARK: - Body Item

private extension ClimbingAnnotation {
    
    func bodyItem(
        icon: String,
        text: String,
        mirrored: Bool = false
    ) -> some View {
        
        VStack(spacing: 3) {
            
            Image(systemName: icon)
                .font(
                    .system(
                        size: 32,
                        weight: .medium
                    )
                )
                .foregroundStyle(.primaryDark)
                .scaleEffect(
                    x: mirrored ? -1 : 1,
                    y: 1
                )
            
            Text(text)
                .font(.body)
                .foregroundStyle(.primaryDark)
        }
    }
}

private func footItem(
    text: String,
    mirrored: Bool = false
) -> some View {
    
    VStack(spacing: 3) {
        
        Image("leftFoot")
            .resizable()
            .scaledToFit()
            .frame(
                width: 32,
                height: 32
            )
            .foregroundStyle(.primaryDark)
            .scaleEffect(
                x: mirrored ? -1 : 1,
                y: 1
            )
        
        Text(text)
            .font(.body)
            .foregroundStyle(.primaryDark)
    }
}

// MARK: - Hold / Movement Button

private extension ClimbingAnnotation {
    
    func holdButton(
        _ title: String
    ) -> some View {
        
        Text(title)
            .font(.body)
            .foregroundStyle(.primaryDark)
            .frame(
                width: 124,
                height: 44
            )
            .background(
                .white.opacity(0.85)
            )
            .clipShape(
                Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(
                        .black.opacity(0.05),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: .black.opacity(0.10),
                radius: 4,
                y: 2
            )
    }
}

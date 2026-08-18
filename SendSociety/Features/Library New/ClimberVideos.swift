//
//  ClimberVideos.swift
//  SendSociety
//
//  Created by Jana Broto on 18/08/26.
//

import SwiftUI


// MARK: - Sample Video Model
struct GalleryItem: Identifiable {
    let id = UUID()
    let date: String
    let time: String
    let grade: String
    let duration: String

}


struct ClimberVideos: View {
    
    // High-density sample collection
        let videos = [
            GalleryItem(date: "28 Jan 2026", time: "1:30 PM", grade: "V2", duration: "02:45"),
            GalleryItem(date: "01 Feb 2026", time: "1:30 PM", grade: "V6", duration: "01:20"),
            GalleryItem(date: "04 Feb 2026", time: "1:30 PM", grade: "V4", duration: "08:12"),
            GalleryItem(date: "18 Feb 2026", time: "1:30 PM", grade: "V7", duration: "00:40"),
            GalleryItem(date: "18 Feb 2026", time: "1:30 PM", grade: "V3", duration: "03:10"),
            GalleryItem(date: "18 Feb 2026", time: "1:30 PM", grade: "V8", duration: "02:05")
        ]
        
        // Multi-column setup optimized for iPad screens & Split View window sizing
        private let columns = [
            GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 24)
        ]
    
    var body: some View {
        NavigationStack {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 32) {
                            ForEach(videos) { video in
                                VideoGridCard(video: video)
                                    .buttonStyle(.plain) // Preserves custom card styling when interactive
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                    }
                    .navigationTitle("Alan Frederick")
                    .background(Color(.systemGroupedBackground))
                    .searchable(text: .constant(""))
            
                    .safeAreaInset(edge: .bottom) {
                        HStack{
                            Spacer()
                            
                            Button(action: {
                                print("Record tapped")
                            }) {
                                ZStack {
                                // The red circle background
                                    Circle()
                                    .fill(.red)
                                    .frame(width: 64, height: 64)
                                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 4)
                                                
                                // The white video camera icon on top
                                    Image(systemName: "video.fill")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                                }
                                .padding(.trailing,40)
                            }
                            .padding(.bottom, 15) // Keeps it safely above the iPad home indicator
                        }
                    }
                }
    }
}

// MARK: - Individual Video Card Layout
struct VideoGridCard: View {
    let video: GalleryItem
    @State private var isHovering = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Thumbnail container
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 16)
                    .fill()
                    .aspectRatio(16/9, contentMode: .fit)
                
                // Visual Anchor: Central Play Graphic
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(radius: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Timestamp Tag
                Text(video.duration)
                    .font(.caption2)
                    .bold()
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.75))
                    .cornerRadius(6)
                    .padding(12)
            }
            // iPadOS Pointer Hover Effect
            .scaleEffect(isHovering ? 1.03 : 1.0)
            .shadow(color: .black.opacity(isHovering ? 0.15 : 0.05), radius: isHovering ? 12 : 6, y: 4)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
            
            // Meta Information Context Block
            HStack(alignment: .bottom, spacing: 4) {
                
                Text(video.date)
                    .font(.headline)
                    .bold()
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                Text(video.time)
                    .font(.default)
                    .tracking(1)
                
                Spacer()
                
                Text(video.grade.uppercased())
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(.accentColor)
                    .tracking(1)
                
            }
            .padding(.horizontal, 4)
        }
    }
}

#Preview {
    ClimberVideos()
}

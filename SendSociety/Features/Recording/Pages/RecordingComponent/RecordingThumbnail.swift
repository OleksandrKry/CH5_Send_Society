//
//  RecordingComponent.swift
//  SendSociety
//
//  Created by Christofer Theodore on 15/08/26.
//

import SwiftUI

/// Horizontal scroll row of every video recorded during this session — tap one to open or switch
/// PlaybackLayerV2's content.
struct RecordingThumbnail: View {
    let videoAttempts: [VideoAttemptV2]
    @Binding var selectedAttempt: VideoAttemptV2?
    
    let sessionController: SessionStoreV2?
    @State private var thumbnails: [UUID: CGImage] = [:]

    var body: some View {
        if !videoAttempts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(videoAttempts) { attempt in
                        thumbnailButton(for: attempt)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func thumbnailButton(for attempt: VideoAttemptV2) -> some View {
        Button {
            selectedAttempt = attempt
        } label: {
            thumbnailImage(for: attempt)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 172, height: 154)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.white, lineWidth: selectedAttempt?.id == attempt.id ? 3 : 0)
                        )
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        .task(id: attempt.id) {
            await loadThumbnailIfNeeded(for: attempt)
        }
    }
    private func thumbnailImage(for attempt: VideoAttemptV2) -> Image {
        if let cgImage = thumbnails[attempt.id] {
            return Image(decorative: cgImage, scale: 1)
        }
        return Image("climbingPlaceholder")
    }

    private func loadThumbnailIfNeeded(for attempt: VideoAttemptV2) async {
        guard thumbnails[attempt.id] == nil, let sessionController else { return }
        let url = sessionController.videoURL(for: attempt)
        let firstFrame = await Task.detached(priority: .utility) {
            VideoFrameExtractor.extractFrame(from: url, atSeconds: 0)
        }.value
        if let firstFrame {
            thumbnails[attempt.id] = firstFrame
        }
    }
}

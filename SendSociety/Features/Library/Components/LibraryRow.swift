//
//  LibraryRow.swift
//  SendSociety
//
//  Created by Christofer Theodore on 16/08/26.
//
import SwiftUI

struct LibraryRow: View {
    let item: LibraryEngine.Item

    private var videoAttempt: VideoAttemptV2 { item.videoAttempt }
    @State private var thumbnails: [UUID: CGImage] = [:]
    let sessionController: SessionStoreV2?

    var body: some View {
        let deviceOrientation = UIDeviceOrientation(rawValue: videoAttempt.recordingDeviceOrientationRawValue)
        ?? .portrait
        
        VStack(alignment: .leading, spacing: 5) {
            // Square thumbnail
            GeometryReader { proxy in
                ZStack {
                    thumbnailImage(for: videoAttempt)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.width
                        )
                        .rotationEffect(.degrees(deviceOrientation == .portrait ? 90 : 0))
                    
                    Image(systemName: "play.fill")
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.6), in: Circle())
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .aspectRatio(1, contentMode: .fit)

            Text(item.climber?.name ?? "Unknown Climber")
                .font(.headline)
                .fontWeight(.medium)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(
                    videoAttempt.createdAt.formatted(
                        date: .abbreviated,
                        time: .omitted
                    )
                )

                Spacer()

                Text(videoAttempt.routeGrade.rawValue)
                
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .task(id: videoAttempt.id) {
            await loadThumbnailIfNeeded(for: videoAttempt)
        }
    }
    
    private func thumbnailImage(for attempt: VideoAttemptV2) -> Image {
        if let cgImage = thumbnails[attempt.id] {
            return Image(decorative: cgImage, scale: 1)
        }
        return Image("climbingPlaceholder")
    }

    private func loadThumbnailIfNeeded(for attempt: VideoAttemptV2) async {
        guard thumbnails[videoAttempt.id] == nil, let sessionController else { return }
        let url = sessionController.videoURL(for: attempt)
        let firstFrame = await Task.detached(priority: .utility) {
            VideoFrameExtractor.extractFrame(from: url, atSeconds: 0)
        }.value
        if let firstFrame {
            thumbnails[attempt.id] = firstFrame
        }
    }

    private var durationLabel: String {
        let totalSeconds = Int(videoAttempt.videoDurationSeconds.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

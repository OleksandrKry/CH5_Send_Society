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
    let recordingSession: RecordingSessionV2?
    @State private var thumbnails: [UUID: CGImage] = [:]
    @State private var attemptPendingDeletion: VideoAttemptV2?

    var body: some View {
        if !videoAttempts.isEmpty {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(Array(videoAttempts.enumerated()), id: \.element.id) { index, attempt in
                        thumbnailButton(for: attempt, index: index)
                    }
                }
                .padding(.vertical, 24)
            }
            .confirmationDialog(
                "Delete this recording?",
                isPresented: Binding(
                    get: { attemptPendingDeletion != nil },
                    set: { isPresented in if !isPresented { attemptPendingDeletion = nil } }
                ),
                presenting: attemptPendingDeletion
            ) { attempt in
                Button("Delete", role: .destructive) { delete(attempt) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This removes the recording and its video file. This can't be undone.")
            }
        }
    }

    private func thumbnailButton(for attempt: VideoAttemptV2, index: Int) -> some View {
        let size: CGFloat = 120

        return ZStack {
            Button {
                selectedAttempt = attempt
            } label: {
                thumbnailImage(for: attempt)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(.white, lineWidth: selectedAttempt?.id == attempt.id ? 3 : 0)
                    )
            }
            .buttonStyle(.plain)

            Button {
                attemptPendingDeletion = attempt
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.red, in: Circle())
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            Text("\(index + 1)")
                .font(.caption.bold())
                .foregroundStyle(.primaryDark)
                .frame(width: 24, height: 24)
                .background(.ultraThinMaterial, in: Circle())
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: size, height: size)
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
    private func delete(_ attempt: VideoAttemptV2) {
        guard let sessionController, let recordingSession else { return }
        sessionController.removeVideoAttempt(attempt.id, from: recordingSession)
        if selectedAttempt?.id == attempt.id {
            selectedAttempt = nil
        }
    }
}

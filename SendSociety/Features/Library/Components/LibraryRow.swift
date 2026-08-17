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
    private var session: RecordingSessionV2 { item.session }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "figure.climbing")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.climber?.name ?? "Unknown Climber")
                    .font(.headline)
                    .lineLimit(1)
                Text(videoAttempt.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label(videoAttempt.routeGrade.rawValue, systemImage: "mountain.2.fill")
                    Label(durationLabel, systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private var durationLabel: String {
        let totalSeconds = Int(videoAttempt.videoDurationSeconds.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

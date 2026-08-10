import SwiftUI

/// One row in the library list — title, relative date, duration, and a badge for how many moments
/// already have a saved 3D reconstruction (feedback item #2's "indicator... so they can revisit
/// the posture again"). Used only by `LibraryView` — pulled into its own file since it's a reusable
/// rendering primitive, not page logic.
struct SessionRow: View {
    let session: RecordingSession

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
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label(durationLabel, systemImage: "clock")
                    if !session.reconstructions.isEmpty {
                        Label("\(session.reconstructions.count) 3D", systemImage: "cube.fill")
                            .foregroundStyle(.teal)
                    }
                    if session.wallScanFolderName != nil {
                        Image(systemName: "square.stack.3d.up.fill")
                            .foregroundStyle(.secondary)
                    }
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
        let totalSeconds = Int(session.videoDurationSeconds.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

import SwiftUI
import AVKit
import ARKit
import simd
import UIKit

/// Reopens a saved `RecordingSession` — the video plays back with its saved 2D annotations
/// reappearing at their timestamps, the scrubber shows tick marks for moments that already have a
/// 3D reconstruction, and tapping a marked moment reloads that EXACT saved reconstruction (via
/// `SavedReconstructionReviewView`) without touching Vision at all.
///
/// A moment with NO saved reconstruction can still get one via "Estimate 3D View"
/// (`generateEstimate()`) — pulling that exact frame out of the saved video file
/// (`VideoFrameExtractor`) and running Vision on it fresh. This is real, but strictly
/// LOWER-FIDELITY than what Step 4 produces live: the original per-frame LiDAR depth/camera-pose
/// data only ever existed in memory during the original AR session (see `RecordedFrameStore`) and
/// was never persisted, so there's no real depth to ground the skeleton in here — it's placed
/// using Vision's own monocular estimate plus the wall's single archived reference camera position
/// as a stand-in for "roughly where the camera was." Every entry this produces is flagged
/// `isApproximate` so the coach always sees an honest "estimated" label, never a confident-looking
/// wrong answer.
struct SessionReviewView: View {
    let session: RecordingSession
    let sessionStore: SessionStore
    let onClose: () -> Void

    private let videoURL: URL
    @StateObject private var model: PlaybackModel
    @StateObject private var annotationState = AnnotationState()
    @State private var isAnnotating = false
    @State private var annotatedTimestamp: Double = 0
    @State private var wallTextureReference: ARSessionManager.WallTextureReference?
    @State private var reviewingEntry: ReconstructionEntry?
    @State private var isGeneratingEstimate = false
    @State private var estimateError: String?

    init(session: RecordingSession, sessionStore: SessionStore, onClose: @escaping () -> Void) {
        self.session = session
        self.sessionStore = sessionStore
        self.onClose = onClose
        let url = sessionStore.videoURL(for: session)
        self.videoURL = url
        _model = StateObject(wrappedValue: PlaybackModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Label("Library", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                Spacer()
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Color.clear.frame(width: 44) // balances the back button so the title stays centered
            }
            .padding()

            ZStack {
                VideoPlayer(player: model.player)
                if isAnnotating {
                    AnnotationOverlay(state: annotationState)
                    if !model.isPlaying {
                        VStack {
                            Spacer()
                            AnnotationToolbar(state: annotationState)
                                .padding(.bottom, 12)
                        }
                    }
                }
            }

            VStack(spacing: 12) {
                reconstructionMarkerTrack
                Slider(
                    value: Binding(
                        get: { model.currentTime },
                        set: { model.seek(to: $0) }
                    ),
                    in: 0...max(model.duration, 0.01),
                    onEditingChanged: { editing in
                        if editing { model.pause() }
                    }
                )
                HStack {
                    Text(model.isPlaying ? "Playing" : "Paused")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !model.isPlaying {
                        Button {
                            isAnnotating.toggle()
                        } label: {
                            Label("Annotate", systemImage: "pencil.tip")
                        }
                        .buttonStyle(.bordered)
                        .tint(isAnnotating ? .orange : nil)
                        .font(.footnote)
                    }
                    Button(model.isPlaying ? "Pause" : "Play") {
                        model.isPlaying ? model.pause() : model.play()
                    }
                }

                if !model.isPlaying {
                    reconstructionAction
                }
            }
            .padding()
        }
        .onAppear {
            wallTextureReference = sessionStore.wallTextureReference(for: session)
            loadAnnotationsForCurrentTime()
        }
        .onChange(of: model.isPlaying) { _, isPlaying in
            if !isPlaying { loadAnnotationsForCurrentTime() }
        }
        .onChange(of: annotationState.strokes) { _, newValue in
            session.setVideoAnnotation(timestampSeconds: annotatedTimestamp, strokes: newValue)
            sessionStore.save()
        }
        .fullScreenCover(item: $reviewingEntry) { entry in
            SavedReconstructionReviewView(
                entry: entry,
                session: session,
                sessionStore: sessionStore,
                wallTextureReference: wallTextureReference,
                onClose: { reviewingEntry = nil }
            )
        }
    }

    /// The saved reconstruction nearest the current paused position, if any is close enough to
    /// count as "this moment" — same 0.3s tolerance `RecordingSession`'s own upsert methods use.
    private var nearbyEntry: ReconstructionEntry? {
        session.reconstructions.first { abs($0.timestampSeconds - model.currentTime) <= 0.3 }
    }

    @ViewBuilder
    private var reconstructionAction: some View {
        if let nearbyEntry {
            Button {
                reviewingEntry = nearbyEntry
            } label: {
                Text("View 3D Reconstruction")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
        } else if isGeneratingEstimate {
            HStack {
                ProgressView()
                Text("Estimating 3D pose…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            VStack(spacing: 8) {
                Button {
                    generateEstimate()
                } label: {
                    Text("Estimate 3D View")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                Text("No LiDAR depth for this moment — this uses Vision's own estimate instead of a precise measurement, and won't classify hand grips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let estimateError {
                    Text(estimateError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// Pulls the current paused frame out of the saved video and runs Vision on it fresh — the
    /// actual algorithm lives in `ReconstructionEstimator` (Core/PoseReconstruction), not here; this
    /// is just wiring the screen's current state to it and updating UI state with the result. Runs
    /// off the main thread since frame extraction + Vision can take a noticeable moment.
    private func generateEstimate() {
        isGeneratingEstimate = true
        estimateError = nil
        let timestamp = model.currentTime
        let url = videoURL
        let reference = wallTextureReference
        // MUST be the orientation the phone was actually held in during this recording, not a
        // fixed assumption — see `ReconstructionEstimator.estimate`'s doc comment for why.
        let deviceOrientation = UIDeviceOrientation(rawValue: session.recordingDeviceOrientationRawValue) ?? .portrait

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entry = try ReconstructionEstimator.estimate(
                    videoURL: url,
                    atSeconds: timestamp,
                    deviceOrientation: deviceOrientation,
                    wallReference: reference
                )
                DispatchQueue.main.async {
                    session.upsertReconstruction(entry)
                    sessionStore.save()
                    isGeneratingEstimate = false
                    // Not surfaced as `estimateError` — setting `reviewingEntry` immediately
                    // presents `SavedReconstructionReviewView` (see its `.fullScreenCover(item:)`
                    // below), so an error message here would never actually be seen. That's fine
                    // even for a wall-only (no-climber) entry — the wall-only view itself is the
                    // useful result, not an error state.
                    reviewingEntry = entry
                }
            } catch {
                DispatchQueue.main.async {
                    isGeneratingEstimate = false
                    estimateError = "Couldn't read a frame from the video at this moment."
                }
            }
        }
    }

    private func loadAnnotationsForCurrentTime() {
        annotatedTimestamp = model.currentTime
        let nearest = session.videoAnnotations.first { abs($0.timestampSeconds - model.currentTime) <= 0.3 }
        annotationState.load(strokes: nearest?.strokes ?? [])
    }

    @ViewBuilder
    private var reconstructionMarkerTrack: some View {
        if !session.reconstructions.isEmpty, model.duration > 0 {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    ForEach(session.reconstructions) { entry in
                        let fraction = min(max(entry.timestampSeconds / model.duration, 0), 1)
                        Circle()
                            .fill(entry.isApproximate ? Color.orange : Color.teal)
                            .frame(width: 6, height: 6)
                            .offset(x: geometry.size.width * fraction - 3)
                    }
                }
            }
            .frame(height: 8)
        }
    }
}

// `SavedReconstructionReviewView` (the fullScreenCover destination that renders a single saved
// `ReconstructionEntry`) has moved to Features/Library/Pages/SavedReconstructionReviewView.swift —
// it's a distinct, self-contained screen rather than a piece of this page's own layout.

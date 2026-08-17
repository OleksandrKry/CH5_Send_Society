import SwiftUI
import SwiftData

/// The app's default landing page — a chronological list of every recorded VIDEO ATTEMPT across
/// every session (flattened, most-recently-recorded first), each showing whether it has saved 3D
/// reconstructions to revisit, with a "New Recording" entry point into the capture pipeline.
///
/// NAVIGATION SHAPE: this is the app's actual root (see `SendSocietyApp`). `ContentView` (the
/// recording pipeline) and `OfflinePlaybackLayer` (revisiting a saved video) are both presented
/// full-screen FROM here and always return back here when done.
///
/// THIS FILE IS UI ONLY. It never talks to `SessionStoreV2` directly for loading/filtering/
/// deleting — it asks `LibraryEngine` to do it. If you're redesigning this screen's look, this is
/// the only file you should need to touch.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext

    // MARK: - Plain on-screen state

    @State private var sessionController: SessionStoreV2?
    @State private var items: [LibraryEngine.Item] = []
    @State private var isPresentingNewRecording = false
    @State private var reviewingItem: LibraryEngine.Item?
    @State private var searchText = ""
    @State private var climberFilter: Climber?

    /// The "brain" for this screen — built fresh from `sessionController` since it holds no state
    /// of its own. nil until `sessionController` exists (see `setUpIfNeeded()`).
    private var engine: LibraryEngine? {
        sessionController.map { LibraryEngine(sessionStore: $0) }
    }

    /// `items`, narrowed down by whatever's typed into the search field.
    private var filteredItems: [LibraryEngine.Item] {
        engine?.items(items, matching: searchText, climberID: climberFilter?.id) ?? []
    }

    var body: some View {
        NavigationStack {
            Group {
                if !LiDARSupport.isSupported {
                    unsupportedDeviceView
                } else if items.isEmpty {
                    emptyStateView
                } else {
                    VStack(spacing: 0) {
                        climberFilterRow
                        itemList
                    }
                }
            }
            .navigationTitle("Send Society")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingNewRecording = true
                    } label: {
                        Label("New Recording", systemImage: "plus.circle.fill")
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search recordings")
        .onAppear(perform: setUpIfNeeded)
        .fullScreenCover(isPresented: $isPresentingNewRecording, onDismiss: reloadItems) {
            ContentView(onFinished: {
                isPresentingNewRecording = false
                reloadItems()
            })
        }
        .fullScreenCover(item: $reviewingItem, onDismiss: reloadItems) { item in
            if let sessionController {
                OfflinePlaybackLayer(
                    videoURL: sessionController.videoURL(for: item.videoAttempt),
                    videoAttempt: item.videoAttempt,
                    recordingSession: item.session,
                    sessionController: sessionController,
                    onDismiss: { reviewingItem = nil }
                )
            }
        }
    }

    private var itemList: some View {
        List {
            ForEach(filteredItems) { item in
                Button {
                    reviewingItem = item
                } label: {
                    LibraryRow(item: item)
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deleteItems)
        }
        .listStyle(.plain)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.climbing")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No recordings yet")
                .font(.title2.bold())
            Text("Tap New Recording to capture your first climb.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button {
                isPresentingNewRecording = true
            } label: {
                Text("New Recording")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unsupportedDeviceView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("LiDAR Required")
                .font(.title2.bold())
            Text("This app needs a LiDAR-equipped iPad to scan the wall and reconstruct 3D pose. This device doesn't support scene reconstruction.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    /// Creates the `SessionStoreV2` (needs `modelContext` from the environment, so it can't be
    /// built any earlier than this) the first time this screen appears, then loads the list.
    private func setUpIfNeeded() {
        guard sessionController == nil else { return }
        sessionController = SessionStoreV2(modelContext: modelContext)
        reloadItems()
    }

    /// Re-reads every saved session's video attempts from disk and re-flattens/re-sorts them.
    /// Call after anything that could have changed the list — finishing a new recording,
    /// returning from a review screen, deleting a row.
    private func reloadItems() {
        items = engine?.loadAllVideoAttempts() ?? []
    }

    private func deleteItems(at offsets: IndexSet) {
        guard let engine else { return }
        for index in offsets {
            engine.delete(filteredItems[index])
        }
        reloadItems()
    }
    private var climberFilterRow: some View {
        HStack {
            Picker("Climber", selection: $climberFilter) {
                Text("All Climbers").tag(Climber?.none)
                ForEach(engine?.fetchAllClimbers() ?? []) { climber in
                    Text(climber.name).tag(Optional(climber))
                }
            }
            .pickerStyle(.menu)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

// `LibraryRow` (one row in the library list) lives in
// Features/Library/Components/LibraryRow.swift.

#Preview {
    LibraryView()
        .modelContainer(for: RecordingSessionV2.self, inMemory: true)
}

#Preview("With sessions") {
    let container = try! ModelContainer(for: RecordingSessionV2.self, configurations: .init(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    for i in 1...3 {
        let session = RecordingSessionV2(ownerID: UUID(), title: "Preview Climb \(i)", wallScanFolderName: nil)
        session.addVideoAttempt(VideoAttemptV2(
            videoFileName: "preview\(i).mp4",
            videoDurationSeconds: Double(30 + i * 15),
            recordingDeviceOrientationRawValue: 1
        ))
        context.insert(session)
    }
    return LibraryView()
        .modelContainer(container)
}

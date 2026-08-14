import SwiftUI
import SwiftData

/// The app's default landing page — a chronological list of every recorded session, each showing
/// whether it has saved 3D reconstructions to revisit, with a "New Recording" entry point into
/// the existing 4-step capture pipeline (`ContentView`).
///
/// NAVIGATION SHAPE: this is the app's actual root (see `SendSocietyApp`). `ContentView` (the
/// Steps 1-4 pipeline) and `SessionReviewView` (revisiting a saved session) are both presented
/// full-screen FROM here and always return back here when done.
///
/// THIS FILE IS UI ONLY. It never talks to `SessionStore` directly for loading/filtering/deleting
/// — it asks `LibraryEngine` (see that file) to do it. If you're redesigning this screen's look,
/// this is the only file you should need to touch.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext

    // MARK: - Plain on-screen state

    @State private var sessionStore: SessionStore?
    @State private var sessions: [RecordingSession] = []
    @State private var isPresentingNewRecording = false
    @State private var reviewingSession: RecordingSession?
    @State private var searchText = ""

    /// The "brain" for this screen — built fresh from `sessionStore` since it holds no state of
    /// its own. nil until `sessionStore` exists (see `setUpIfNeeded()`).
    private var engine: LibraryEngine? {
        sessionStore.map { LibraryEngine(sessionStore: $0) }
    }

    /// `sessions`, narrowed down by whatever's typed into the search field.
    private var filteredSessions: [RecordingSession] {
        engine?.sessions(sessions, matching: searchText) ?? []
    }

    var body: some View {
        NavigationStack {
            Group {
                if !LiDARSupport.isSupported {
                    unsupportedDeviceView
                } else if sessions.isEmpty {
                    emptyStateView
                } else {
                    sessionList
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
        .fullScreenCover(isPresented: $isPresentingNewRecording, onDismiss: reloadSessions) {
            ContentView(onFinished: {
                isPresentingNewRecording = false
                reloadSessions()
            })
        }
        .fullScreenCover(item: $reviewingSession, onDismiss: reloadSessions) { session in
            if let sessionStore {
                SessionReviewView(session: session, sessionStore: sessionStore, onClose: {
                    reviewingSession = nil
                })
            }
        }
    }

    private var sessionList: some View {
        List {
            ForEach(filteredSessions) { session in
                Button {
                    reviewingSession = session
                } label: {
                    SessionRow(session: session)
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deleteSessions)
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
    // Functions a redesigned View's buttons/lifecycle hooks should call.

    /// Creates the `SessionStore` (needs `modelContext` from the environment, so it can't be
    /// built any earlier than this) the first time this screen appears, then loads the list.
    private func setUpIfNeeded() {
        guard sessionStore == nil else { return }
        sessionStore = SessionStore(modelContext: modelContext)
        reloadSessions()
    }

    /// Re-reads every saved session from disk. Call after anything that could have changed the
    /// list — finishing a new recording, returning from a review screen, deleting a row.
    private func reloadSessions() {
        sessions = engine?.loadAllSessions() ?? []
    }

    private func deleteSessions(at offsets: IndexSet) {
        guard let engine else { return }
        for index in offsets {
            engine.deleteSession(filteredSessions[index])
        }
        reloadSessions()
    }
}

// `SessionRow` (one row in the library list) lives in
// Features/Library/Components/SessionRow.swift — a reusable rendering primitive, not page logic,
// so it lives separately for a frontend developer to find and edit on its own.

// Preview note: an in-memory, throwaway SwiftData store — nothing here touches the real on-device
// database. Shows the empty state (no sessions yet); see `#Preview("With sessions")` below for the
// populated list layout.
#Preview {
    LibraryView()
        .modelContainer(for: RecordingSession.self, inMemory: true)
}

#Preview("With sessions") {
    let container = try! ModelContainer(for: RecordingSession.self, configurations: .init(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    for i in 1...3 {
        let session = RecordingSession(
            ownerID: UUID(),
            title: "Preview Climb \(i)",
            videoFileName: "preview\(i).mp4",
            videoDurationSeconds: Double(30 + i * 15),
            recordingDeviceOrientationRawValue: 1
        )
        context.insert(session)
    }
    return LibraryView()
        .modelContainer(container)
}

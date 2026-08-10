import SwiftUI
import SwiftData

/// The app's default landing page (feedback item #2) — an OnForm-style chronological list of
/// every recorded session, each showing whether it has saved 3D reconstructions to revisit, with
/// a "New Recording" entry point into the existing 4-step capture pipeline (`ContentView`).
///
/// NAVIGATION SHAPE: this is now the app's actual root (see `SendSocietyApp`). `ContentView` (the
/// Steps 1-4 pipeline) and `SessionReviewView` (revisiting a saved session) are both presented
/// full-screen FROM here and always return back here when done — neither one is reachable any
/// other way anymore.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var sessionStore: SessionStore?
    @State private var sessions: [RecordingSession] = []
    @State private var isPresentingNewRecording = false
    @State private var reviewingSession: RecordingSession?
    @State private var searchText = ""

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
        .onAppear {
            if sessionStore == nil {
                sessionStore = SessionStore(modelContext: modelContext)
            }
            refresh()
        }
        .fullScreenCover(isPresented: $isPresentingNewRecording, onDismiss: refresh) {
            ContentView(onFinished: {
                isPresentingNewRecording = false
                refresh()
            })
        }
        .fullScreenCover(item: $reviewingSession, onDismiss: refresh) { session in
            if let sessionStore {
                SessionReviewView(session: session, sessionStore: sessionStore, onClose: {
                    reviewingSession = nil
                })
            }
        }
    }

    private func refresh() {
        sessions = sessionStore?.fetchAll() ?? []
    }

    private var filteredSessions: [RecordingSession] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
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
            .onDelete(perform: delete)
        }
        .listStyle(.plain)
    }

    private func delete(at offsets: IndexSet) {
        guard let sessionStore else { return }
        for index in offsets {
            sessionStore.delete(filteredSessions[index])
        }
        refresh()
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.climbing")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No recordings yet")
                .font(.title2.bold())
            Text("Tap New Recording to scan a wall, calibrate a climber, and capture your first climb.")
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
}

// `SessionRow` (one row in the library list) has moved to Features/Library/Components/SessionRow.swift
// — a reusable rendering primitive, not page logic, so it lives separately for a frontend developer
// to find and edit on its own.

import Foundation

/// LibraryEngine is the "brain" behind the recordings list screen. It holds no state of its own
/// — it just wraps `SessionStore` (the real on-disk storage) with three plain, easy-to-read
/// functions. The View is responsible for holding onto whatever these functions return.
///
/// `@MainActor` because every function here calls into `SessionStore`, which is itself
/// `@MainActor`-isolated (SwiftData's `ModelContext` isn't safe to touch off the main thread) —
/// this engine is only ever created and called from a View anyway (already on the main thread),
/// so this just tells the compiler what was already true.
@MainActor
struct LibraryEngine {
    let sessionStore: SessionStore

    /// Every saved session, in whatever order `SessionStore.fetchAll()` returns them.
    func loadAllSessions() -> [RecordingSession] {
        sessionStore.fetchAll()
    }

    /// Filters `sessions` down to ones whose title contains `searchText` (case-insensitive).
    /// Returns `sessions` unchanged when `searchText` is empty.
    func sessions(_ sessions: [RecordingSession], matching searchText: String) -> [RecordingSession] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// Permanently deletes `session` from disk.
    func deleteSession(_ session: RecordingSession) {
        sessionStore.delete(session)
    }
}

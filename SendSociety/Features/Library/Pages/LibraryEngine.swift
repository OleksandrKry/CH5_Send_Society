import Foundation

@MainActor
struct LibraryEngine {
    let sessionStore: SessionStoreV2

    struct Item: Identifiable {
        let videoAttempt: VideoAttemptV2
        let session: RecordingSessionV2

        var id: UUID { videoAttempt.id }
    }

    func loadAllVideoAttempts() -> [Item] {
        sessionStore.fetchAll()
            .flatMap { session in
                session.videoAttempts.map { Item(videoAttempt: $0, session: session) }
            }
            .sorted { $0.videoAttempt.createdAt > $1.videoAttempt.createdAt }
    }

    func items(_ items: [Item], matching query: String) -> [Item] {
        guard !query.isEmpty else { return items }
        return items.filter { $0.session.title.localizedCaseInsensitiveContains(query) }
    }

    func delete(_ item: Item) {
        sessionStore.removeVideoAttempt(item.videoAttempt.id, from: item.session)
    }
}

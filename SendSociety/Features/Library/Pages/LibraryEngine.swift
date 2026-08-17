import Foundation

@MainActor
struct LibraryEngine {
    let sessionStore: SessionStoreV2

    struct Item: Identifiable {
        let videoAttempt: VideoAttemptV2
        let session: RecordingSessionV2
        let climber: Climber?

        var id: UUID { videoAttempt.id }
    }

    func loadAllVideoAttempts() -> [Item] {
        let climbersByID = Dictionary(uniqueKeysWithValues: sessionStore.fetchAllClimbers().map { ($0.id, $0) })
        return sessionStore.fetchAll()
            .flatMap { session in
                session.videoAttempts.map { attempt in
                    Item(videoAttempt: attempt, session: session, climber: attempt.climberID.flatMap { climbersByID[$0] })
                }
            }
            .sorted { $0.videoAttempt.createdAt > $1.videoAttempt.createdAt }
    }

    func items(_ items: [Item], matching query: String, climberID: UUID? = nil) -> [Item] {
        var result = items
        if let climberID {
            result = result.filter { $0.videoAttempt.climberID == climberID }
        }
        guard !query.isEmpty else { return result }
        return result.filter { $0.session.title.localizedCaseInsensitiveContains(query) }
    }

    func delete(_ item: Item) {
        sessionStore.removeVideoAttempt(item.videoAttempt.id, from: item.session)
    }
    func fetchAllClimbers() -> [Climber] {
        sessionStore.fetchAllClimbers()
    }
}

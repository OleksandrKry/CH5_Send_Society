import Foundation

/// The current app "user" — for this MVP that's always a locally-generated guest identity, never
/// a real signed-in account. Every saved `RecordingSession` is tagged with `UserIdentity.current.id`
/// so the data model already has a real owner concept, even though there's no login yet.
///
/// UPGRADE PATH (when real registration/login ships): keep this exact `id` — don't generate a new
/// one. The natural migration is "claim this guest ID": when the coach signs up or logs in for the
/// first time, associate their new server-side account with the SAME UUID already stamped on all
/// their local recordings, so existing history transfers over instead of orphaning it. That's why
/// `id` is a stable `UUID`, not something derived from a future username/email — it's designed to
/// outlive the "guest" label, not to be thrown away once real auth exists.
struct UserIdentity {
    let id: UUID
    /// Always true for now. Flip to false (and add real profile fields — name, email, etc.) once
    /// registration/login exists; nothing else in the persistence layer needs to change, since
    /// every record is already keyed by `id`, not by "guest-ness."
    let isGuest: Bool

    /// Stored in UserDefaults, not Keychain — simplest option, and fine as long as this ID's only
    /// job is "distinguish one install's recordings from another's." The real trade-off: UserDefaults
    /// is wiped on uninstall, so a coach who deletes the app before ever registering loses the link
    /// to their old guest recordings. If that turns out to matter in practice, moving this one value
    /// to Keychain (which survives uninstall) is a small, isolated change — everything else in the
    /// persistence layer only ever sees `UserIdentity.current.id` and doesn't care where it lives.
    private static let storageKey = "com.sendsociety.guestUserID"

    /// The single shared identity for this install. Loaded once, cached for the process lifetime.
    static let current: UserIdentity = {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: storageKey), let uuid = UUID(uuidString: stored) {
            return UserIdentity(id: uuid, isGuest: true)
        }
        let newID = UUID()
        defaults.set(newID.uuidString, forKey: storageKey)
        DebugLog.general.info("Generated new guest identity \(newID.uuidString, privacy: .public)")
        return UserIdentity(id: newID, isGuest: true)
    }()
}

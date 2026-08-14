import Foundation
import SwiftData

/// THE FRONT DOOR TO PERSISTENCE. Every screen — Library, the recording pipeline, session review —
/// creates/reads/updates/deletes a `RecordingSession` through this type ONLY. `SessionFileStore`
/// and `WallScanArchive` are this module's private implementation details: they know how to lay
/// out files on disk, but nothing outside `Core/Persistence` should call them directly, construct
/// a `ModelContext` query itself, or read `RecordingSession`'s stored properties as file paths.
/// Going through `SessionStore` instead of one of those means a frontend/backend developer editing
/// a screen can't accidentally corrupt on-disk layout or bypass the error-handling this type
/// centralizes (see `createSession`'s doc comment for a concrete example of why that matters).
///
/// This boundary is enforced by CONVENTION and code review, not by the Swift compiler — this
/// project is one single app target (no separate Swift Package for persistence), so
/// `SessionFileStore`/`WallScanArchive` are technically reachable from anywhere. Treat them as if
/// they were `private`: if you find yourself typing `SessionFileStore.` or `WallScanArchive.`
/// outside this folder, that's a sign a method belongs on `SessionStore` instead (add one rather
/// than reaching around it — see `videoURL(for:)` below for the pattern).
@MainActor
final class SessionStore: ObservableObject {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Creates and saves a new `RecordingSession` from a just-completed recording. `videoTempURL`
    /// is wherever `VideoRecorder` wrote the file (its temporary-directory output) — this copies it
    /// into permanent storage itself, so callers don't need to know about `SessionFileStore`.
    /// `wallTextureReference` is optional since a session is still worth saving even if Step 1
    /// never captured a usable reference frame.
    ///
    /// THROWS instead of returning nil on failure — see `SessionFileStore.moveVideoIntoPermanentStorage`'s
    /// doc comment for why: a silent failure here previously meant the entire recording flow
    /// would complete normally and return to an empty Library list with zero on-screen indication
    /// anything had gone wrong. Callers should catch this and show the coach something readable.
    @discardableResult
    func createSession(
        title: String,
        videoTempURL: URL,
        videoDurationSeconds: Double,
        recordingDeviceOrientationRawValue: Int,
        wallTextureReference: ARSessionManager.WallTextureReference?
    ) throws -> RecordingSession {
        let videoFileName = try SessionFileStore.moveVideoIntoPermanentStorage(from: videoTempURL)

        var wallScanFolderName: String?
        if let wallTextureReference {
            let folderName = UUID().uuidString
            wallScanFolderName = WallScanArchive.save(wallTextureReference, folderName: folderName, in: SessionFileStore.wallScansDirectory)
            if wallScanFolderName == nil {
                DebugLog.reconstruction.error("SessionStore: wall scan archive failed — saving session without a revisitable wall")
            }
        }

        let session = RecordingSession(
            ownerID: UserIdentity.current.id,
            title: title,
            videoFileName: videoFileName,
            videoDurationSeconds: videoDurationSeconds,
            recordingDeviceOrientationRawValue: recordingDeviceOrientationRawValue,
            wallScanFolderName: wallScanFolderName
        )
        modelContext.insert(session)
        do {
            try modelContext.save()
        } catch {
            // Roll the insert back rather than leaving a half-saved object sitting in the context —
            // otherwise a later, unrelated `save()` elsewhere could flush this same failed session
            // to disk anyway, silently "fixing" itself in a confusing way.
            modelContext.delete(session)
            DebugLog.general.error("SessionStore: modelContext.save() failed while creating session: \(String(describing: error), privacy: .public)")
            throw error
        }
        return session
    }

    /// All sessions belonging to the current identity, newest first — the Library screen's data
    /// source. Filters by `ownerID` even though there's only ever one guest identity per install
    /// today, so this doesn't need to change once real multi-account login exists.
    func fetchAll() -> [RecordingSession] {
        let ownerID = UserIdentity.current.id
        let descriptor = FetchDescriptor<RecordingSession>(
            predicate: #Predicate { $0.ownerID == ownerID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func delete(_ session: RecordingSession) {
        SessionFileStore.deleteVideo(fileName: session.videoFileName)
        if let wallScanFolderName = session.wallScanFolderName {
            WallScanArchive.delete(folderName: wallScanFolderName, from: SessionFileStore.wallScansDirectory)
        }
        modelContext.delete(session)
        save()
    }

    /// Call after mutating a fetched `RecordingSession`'s properties in place (e.g. appending a
    /// video annotation or upserting a reconstruction) — SwiftData tracks the change automatically,
    /// but an explicit save flushes it to disk right away rather than whenever the context next
    /// happens to save on its own.
    func save() {
        do {
            try modelContext.save()
        } catch {
            DebugLog.general.error("SessionStore: modelContext.save() failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Loads the archived wall scan for `session`, if it has one — used by session review to
    /// rebuild the Step 4 wall without a live ARSession.
    func wallTextureReference(for session: RecordingSession) -> ARSessionManager.WallTextureReference? {
        guard let folderName = session.wallScanFolderName else { return nil }
        return WallScanArchive.load(folderName: folderName, from: SessionFileStore.wallScansDirectory)
    }

    /// Resolves `session`'s saved video to a playable file URL. Added so callers (e.g.
    /// `SessionReviewView`) never need to know `RecordingSession.videoFileName` is "just a
    /// filename, resolve it against `SessionFileStore`" — that's exactly the kind of on-disk-layout
    /// detail this facade exists to hide (see this type's doc comment).
    func videoURL(for session: RecordingSession) -> URL {
        SessionFileStore.videoURL(for: session.videoFileName)
    }
}

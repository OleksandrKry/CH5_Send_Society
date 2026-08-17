//
//  SessionStoreV2.swift
//  SendSociety
//
//  Created by Christofer Theodore on 14/08/26.
//

import Foundation
import SwiftData

@MainActor
final class SessionStoreV2: ObservableObject {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    /// Creates and saves a new RecordingSessionV2 with NO video attempts yet. Call this once,
    /// when the wall scan is ready to be committed.
    @discardableResult
    func createSession(
        title: String,
        wallTextureReference: ARSessionManager.WallTextureReference?
    ) throws -> RecordingSessionV2 {
        var wallScanFolderName: String?
        if let wallTextureReference {
            let folderName = UUID().uuidString
            wallScanFolderName = WallScanArchive.save(wallTextureReference, folderName: folderName, in: SessionFileStore.wallScansDirectory)
            if wallScanFolderName == nil {
                DebugLog.reconstruction.error("SessionStoreV2: wall scan archive failed — saving session without a revisitable wall")
            }
        }

        let session = RecordingSessionV2(
            ownerID: UserIdentity.current.id,
            title: title,
            wallScanFolderName: wallScanFolderName
        )
        modelContext.insert(session)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(session)
            DebugLog.general.error("SessionStoreV2: modelContext.save() failed while creating session: \(String(describing: error), privacy: .public)")
            throw error
        }
        return session
    }
    /// All wall-scan sessions belonging to the current identity, newest first.
    func fetchAll() -> [RecordingSessionV2] {
        let ownerID = UserIdentity.current.id
        let descriptor = FetchDescriptor<RecordingSessionV2>(
            predicate: #Predicate { $0.ownerID == ownerID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Deletes a whole session: every recorded video's file, the archived wall scan, and the
    /// model itself.
    func delete(_ session: RecordingSessionV2) {
        for attempt in session.videoAttempts {
            SessionFileStore.deleteVideo(fileName: attempt.videoFileName)
        }
        if let wallScanFolderName = session.wallScanFolderName {
            WallScanArchive.delete(folderName: wallScanFolderName, from: SessionFileStore.wallScansDirectory)
        }
        modelContext.delete(session)
        save()
    }

    /// Call after mutating a fetched RecordingSessionV2 in place — flushes to disk right away.
    func save() {
        do {
            try modelContext.save()
        } catch {
            DebugLog.general.error("SessionStoreV2: modelContext.save() failed: \(String(describing: error), privacy: .public)")
        }
    }
    /// Moves a just-finished recording into permanent storage and appends it to session as a new
    /// VideoAttemptV2. Call once per "record → stop" cycle.
    @discardableResult
    func addVideoAttempt(
        to session: RecordingSessionV2,
        videoTempURL: URL,
        videoDurationSeconds: Double,
        recordingDeviceOrientationRawValue: Int,
        clipStartTimestamp: TimeInterval
    ) throws -> VideoAttemptV2 {
        let videoFileName = try SessionFileStore.moveVideoIntoPermanentStorage(from: videoTempURL)
        let attempt = VideoAttemptV2(
            videoFileName: videoFileName,
            videoDurationSeconds: videoDurationSeconds,
            recordingDeviceOrientationRawValue: recordingDeviceOrientationRawValue,
            clipStartTimestamp: clipStartTimestamp
        )
        session.addVideoAttempt(attempt)
        save()
        return attempt
    }
    
    /// Resolves one video attempt's saved file to a playable URL.
    func videoURL(for attempt: VideoAttemptV2) -> URL {
        SessionFileStore.videoURL(for: attempt.videoFileName)
    }

    /// Deletes one recorded take: removes its video file from disk AND removes its entry from
    /// session.videoAttempts. No-op if attemptID isn't found.
    func removeVideoAttempt(_ attemptID: UUID, from session: RecordingSessionV2) {
        guard let attempt = session.videoAttempt(id: attemptID) else { return }
        SessionFileStore.deleteVideo(fileName: attempt.videoFileName)
        session.removeVideoAttempt(id: attemptID)
        save()
    }

    /// Writes an updated VideoAttemptV2 back onto session and flushes to disk.
    func save(_ attempt: VideoAttemptV2, in session: RecordingSessionV2) {
        session.updateVideoAttempt(attempt)
        save()
    }
    
    /// Reloads the wall scan archived for this session (written once, at `createSession` time) back
    /// into a `WallTextureReference` — used by offline review, which has no live AR session to read
    /// the wall from directly. Shared by every VideoAttemptV2 in the session (one wall per wall-scan
    /// session, unlike the old flow's one-wall-per-video).
    func wallTextureReference(for session: RecordingSessionV2) -> ARSessionManager.WallTextureReference? {
        guard let wallScanFolderName = session.wallScanFolderName else { return nil }
        return WallScanArchive.load(folderName: wallScanFolderName, from: SessionFileStore.wallScansDirectory) // exact call TBD from the real file
    }
}

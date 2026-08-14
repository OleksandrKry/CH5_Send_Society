//
//  RecordingSessionV2.swift
//  SendSociety
//
//  Created by Christofer Theodore on 14/08/26.
//

import Foundation
import SwiftData
import simd

@Model
final class RecordingSessionV2 {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var createdAt: Date
    var title: String

    /// Folder name holding this session's archived wall scan — unchanged in meaning from old
    /// RecordingSession.wallScanFolderName. Stays at the SESSION level (not per-video) because
    /// there's still only ever one wall scan per session.
    var wallScanFolderName: String?

    /// JSON-encoded [VideoAttemptV2] — every clip recorded during this session, oldest first.
    /// We'll add the computed accessor for this in the next step.
    var videoAttemptsData: Data

    init(
        id: UUID = UUID(),
        ownerID: UUID,
        createdAt: Date = Date(),
        title: String,
        wallScanFolderName: String? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.createdAt = createdAt
        self.title = title
        self.wallScanFolderName = wallScanFolderName
        self.videoAttemptsData = (try? JSONEncoder().encode([VideoAttemptV2]())) ?? Data()
    }
    var videoAttempts: [VideoAttemptV2] {
        get { (try? JSONDecoder().decode([VideoAttemptV2].self, from: videoAttemptsData)) ?? [] }
        set { videoAttemptsData = (try? JSONEncoder().encode(newValue)) ?? videoAttemptsData }
    }
    
    /// Appends a newly-recorded clip. Call once per "record → stop" cycle, right after the video
    /// file has been moved into permanent storage. Videos stay in recording order (oldest first).
    func addVideoAttempt(_ attempt: VideoAttemptV2) {
        videoAttempts.append(attempt)
    }

    /// Looks up one video attempt by id — e.g. to load it when the coach taps its thumbnail.
    func videoAttempt(id: UUID) -> VideoAttemptV2? {
        videoAttempts.first { $0.id == id }
    }

    /// Call after mutating a fetched VideoAttemptV2 in place, to write the change back.
    func updateVideoAttempt(_ attempt: VideoAttemptV2) {
        var all = videoAttempts
        guard let index = all.firstIndex(where: { $0.id == attempt.id }) else { return }
        all[index] = attempt
        videoAttempts = all
    }

    /// Removes one recorded take from the model. Does NOT delete the underlying video file on
    /// disk — that's a file-system concern, and belongs in SessionStore, not here.
    func removeVideoAttempt(id: UUID) {
        videoAttempts.removeAll { $0.id == id }
    }
}

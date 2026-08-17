//
//  Climber.swift
//  SendSociety
//
//  Created by Christofer Theodore on 17/08/26.
//

import Foundation
import SwiftData

/// A climber a coach has recorded before — its own table, not a string on `VideoAttemptV2`, so
/// "list all climbers" is a direct indexed query instead of scanning and deduping every video
/// attempt across every session. Keyed by `ownerID` exactly like `RecordingSessionV2`, for the
/// same reason (no real accounts yet — see `UserIdentity`).
@Model
final class Climber {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), ownerID: UUID, name: String, createdAt: Date = Date()) {
        self.id = id
        self.ownerID = ownerID
        self.name = name
        self.createdAt = createdAt
    }
}

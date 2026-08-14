//
//  VideoAnotateMarker.swift
//  SendSociety
//
//  Created by Christofer Theodore on 14/08/26.
//
import Foundation

struct VideoMarkerModel: Identifiable {
    let id: UUID
    /// Where this moment sits in the video, in seconds from the start.
    let videoTimeInSeconds: Double
    /// True if there's a saved drawing (pen/line/angle markup) at this moment.
    let hasDrawing: Bool
    /// True if there's a saved 3D pose reconstruction at this moment.
    let has3DPose: Bool
    /// True if the 3D pose was ESTIMATED after the fact (no real depth data), rather than
    /// measured live with LiDAR during recording. Only meaningful when `has3DPose` is true.
    let is3DPoseApproximate: Bool
}

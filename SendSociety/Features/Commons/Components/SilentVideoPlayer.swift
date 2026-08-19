//
//  SilentVideoPlayer.swift
//  SendSociety
//
//  Created by Christofer Theodore on 20/08/26.
//

import SwiftUI
import AVKit

/// Same pattern as `ARMeshSceneView` — SwiftUI's own `VideoPlayer` wraps `AVPlayerViewController`
/// internally but never exposes it, so there's no way to reach `showsPlaybackControls` through it.
/// Wrapping the UIKit type ourselves is the only way to turn off AVKit's tap-to-reveal transport UI.
struct SilentVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
    }
}

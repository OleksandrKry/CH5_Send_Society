import SwiftUI
import UIKit

@main
struct SendSocietyApp: App {
    init() {
        // Needed so UIDevice.current.orientation reflects live changes — used by
        // BodyPose3DExtractor to pick the correct CGImagePropertyOrientation for Vision.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

import SwiftUI
import UIKit
import SwiftData

@main
struct SendSocietyApp: App {
    init() {
        // Needed so UIDevice.current.orientation reflects live changes — used by
        // BodyPose3DExtractor to pick the correct CGImagePropertyOrientation for Vision.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        // Fire-and-forget: warms up the YOLO model on its own dedicated queue (see
        // `YOLOBodyPoseDetector.queue`'s doc comment) as soon as the app launches, so the first
        // real use — Step 2's capture loop or Step 4's `generate()`, both of which currently call
        // into it synchronously on the MAIN thread — doesn't have to eat the (potentially
        // multi-second, first-time-only) model load cost as a UI freeze. No-op cost when
        // `useYOLO` is off.
        if PoseDetectionSettings.useYOLO {
            YOLOBodyPoseDetector.preload()
        }
    }

    var body: some Scene {
        WindowGroup {
            // LibraryView is the app's actual root now — see its doc comment for the overall
            // navigation shape. ContentView (the Steps 1-4 capture pipeline) is presented FROM it.
            LibraryView()
        }
        // Registers the persistence schema for the whole app — `RecordingSession` is the only
        // `@Model` type (see its doc comment for why child data is flattened into it as JSON
        // rather than being separate related models). This also makes `\.modelContext` available
        // via `@Environment` anywhere in the view hierarchy, which is how `LibraryView`/
        // `ContentView` construct their `SessionStore`.
        .modelContainer(for: RecordingSession.self)
    }
}

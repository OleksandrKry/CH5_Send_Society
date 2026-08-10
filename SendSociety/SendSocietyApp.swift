import SwiftUI
import UIKit
import SwiftData

@main
struct SendSocietyApp: App {
    init() {
        // Needed so UIDevice.current.orientation reflects live changes — used by
        // BodyPose3DExtractor to pick the correct CGImagePropertyOrientation for Vision.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
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

import SwiftUI
import UIKit
import SwiftData

@main
struct SendSocietyApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    init() {
        // Needed so UIDevice.current.orientation reflects live changes — used by
        // BodyPose3DExtractor to pick the correct CGImagePropertyOrientation for Vision.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                LibraryView()
            } else {
//                OnboardingFlow(onComplete: { hasCompletedOnboarding = true })
                InitialScreen(onFinish: { hasCompletedOnboarding = true })
            }
        }
        // Registers the persistence schema for the whole app — `RecordingSession` is the only
        // `@Model` type (see its doc comment for why child data is flattened into it as JSON
        // rather than being separate related models). This also makes `\.modelContext` available
        // via `@Environment` anywhere in the view hierarchy, which is how `LibraryView`/
        // `ContentView` construct their `SessionStore`.
        .modelContainer(for: [RecordingSessionV2.self, Climber.self])
    }
}

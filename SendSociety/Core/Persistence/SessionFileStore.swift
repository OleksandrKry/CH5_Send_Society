import Foundation

/// IMPLEMENTATION DETAIL OF `SessionStore` — do not call this from outside `Core/Persistence`. See
/// `SessionStore`'s doc comment for why, and add a method there instead of reaching in here.
///
/// Where saved sessions' big binary files (recorded video, archived wall scans) live on disk.
/// `RecordingSession` itself only stores FILENAMES/FOLDER NAMES (not full paths — the app
/// container path isn't stable across installs/OS updates), resolved against these directories at
/// read time.
///
/// Uses Application Support (not Documents) since these are app-managed working files a coach
/// never needs to see in the Files app — matches Apple's guidance for data the app owns and
/// recreates its own view of, as opposed to user-generated documents.
enum SessionFileStore {
    private static let fileManager = FileManager.default

    private static var applicationSupportDirectory: URL {
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SendSociety", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var recordingsDirectory: URL {
        let url = applicationSupportDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var wallScansDirectory: URL {
        let url = applicationSupportDirectory.appendingPathComponent("WallScans", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func videoURL(for fileName: String) -> URL {
        recordingsDirectory.appendingPathComponent(fileName)
    }

    /// Copies a just-recorded video out of `VideoRecorder`'s temporary output location into
    /// permanent storage, so it survives past this run of the app (temp-directory files can be
    /// purged by the OS at any time). Returns the new filename (not a full path) to store on
    /// `RecordingSession.videoFileName`.
    ///
    /// Copies rather than moves: `VideoRecorder`/`RecordingView`/`ReconstructionInput` may still
    /// hold and use the original temp URL for the remainder of this same app run (e.g. Step 4's
    /// `AVPlayer` was already pointed at it), so removing the temp file out from under them is an
    /// avoidable risk for the sake of a little disk space the OS will reclaim anyway.
    ///
    /// THROWS (rather than returning nil) so the caller can surface the REAL reason to the coach —
    /// this was previously a silent nil-return, logged only via `DebugLog`, which meant a save
    /// failure with no cable/console attached looked EXACTLY like a successful save that just
    /// wasn't there: the whole 4-step flow completed normally, "Done" returned to an empty Library
    /// list, with nothing on screen ever indicating why. The most likely real-world cause is the
    /// device being low on storage (`.mp4`s are large, and this exact bug was found right after a
    /// stretch of crash-testing that could easily have left several orphaned temp recordings sitting
    /// around) — that's now something the coach can actually read and act on instead of guessing.
    static func moveVideoIntoPermanentStorage(from tempURL: URL) throws -> String {
        let fileName = UUID().uuidString + ".mp4"
        let destination = videoURL(for: fileName)
        do {
            try fileManager.copyItem(at: tempURL, to: destination)
            return fileName
        } catch {
            DebugLog.recording.error("SessionFileStore: failed to copy video into permanent storage: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    static func deleteVideo(fileName: String) {
        try? fileManager.removeItem(at: videoURL(for: fileName))
    }
}

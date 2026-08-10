import Foundation

/// Lightweight device/process health readouts for diagnosing the "app crashes during recording"
/// report — recording is the single heaviest sustained workload in this app (per-frame
/// `CVPixelBuffer` deep-copies in `RecordedFrameStore`, live video encoding via `AVAssetWriter`,
/// ARKit's own scene reconstruction + tracking, all running at once), so if something's going to
/// run the device out of memory or into thermal throttling, this is where it'll show up first.
///
/// Neither of these is exposed by a convenient high-level API, but both techniques below are
/// long-standing, widely used patterns for exactly this kind of lightweight in-app diagnostic —
/// still UNVERIFIED ON DEVICE like everything else added without a compiler in this pass.
enum DeviceDiagnostics {
    /// Approximate resident memory footprint of this process, in megabytes, via `task_info`/
    /// `mach_task_basic_info` — the same low-level call Xcode's own memory gauge is built on.
    /// Returns nil if the underlying `task_info` call fails for any reason.
    static func residentMemoryMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { infoPointer -> kern_return_t in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    static var thermalStateDescription: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// One-line health snapshot, meant to be logged periodically (NOT per-frame — see
    /// `VideoRecorder`'s throttled diagnostic logging) so a device console pull shows a timeline
    /// of memory climbing and/or thermal state worsening in the run-up to a crash.
    static var summary: String {
        let memory = residentMemoryMB().map { String(format: "%.0fMB", $0) } ?? "unknown"
        return "memory=\(memory) thermal=\(thermalStateDescription)"
    }
}

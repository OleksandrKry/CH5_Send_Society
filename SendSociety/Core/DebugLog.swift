import Foundation
import os

/// Structured logging aligned to the MVP success criteria in the build brief. Each criterion
/// gets its own OSLog category so device console output (Console.app / Xcode) can be filtered
/// per-question during a test session:
///
/// 1. wallScan        — is the wall mesh usable/complete in normal gym lighting?
/// 2. recording         — does depth stay correctly associated with each video frame?
/// 3. reconstruction   — does the skeleton line up with the wall in Step 4?
/// 4. tracking          — does tracking survive handheld use, or is a tripod required?
enum DebugLog {
    private static let subsystem = "com.sendsociety.climbcoach"

    static let wallScan = Logger(subsystem: subsystem, category: "1-wall-mesh-quality")
    static let recording = Logger(subsystem: subsystem, category: "3-depth-frame-association")
    static let reconstruction = Logger(subsystem: subsystem, category: "4-alignment")
    static let tracking = Logger(subsystem: subsystem, category: "5-tracking-robustness")
    static let general = Logger(subsystem: subsystem, category: "general")
}

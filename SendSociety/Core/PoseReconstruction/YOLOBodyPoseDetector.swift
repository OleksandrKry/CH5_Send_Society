import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import UltralyticsYOLO

/// Single on/off switch for which body-pose detection backend the app's LiDAR-grounded paths
/// (Step 2 calibration, Step 4 Generate) use: Apple's Vision framework
/// (`VNDetectHumanBodyPose3DRequest`, the original, already-working path) or the newly-added
/// YOLO26-pose CoreML model (`YOLOBodyPoseDetector`, below). Defaults to `false` (Vision) — flip
/// `useYOLO` back to `false` at any point to instantly revert to the previously-working
/// Vision-only pipeline if YOLO underperforms on real hardware; nothing else in the app needs to
/// change for that rollback, since both backends are kept fully intact side by side rather than
/// one replacing the other.
///
/// "Estimate 3D" (`ReconstructionEstimator`) is NOT gated by this switch — per an explicit product
/// decision, it always combines both backends (YOLO's 2D joint positions + Vision's own depth
/// estimate for those same joints), since Vision is the only available source of a depth guess
/// once there's no real LiDAR data to ground against. See that type's doc comment once it's wired
/// up.
enum PoseDetectionSettings {
    // The original `yolo26n-pose.mlpackage` export hit a confirmed Apple OS bug on iOS 26.4+
    // (hang inside Core ML's on-device AOT recompilation for ML Program/"E5" models — doesn't
    // respond to computeUnits changes, not catchable from Swift). Tried the legacy
    // `yolo11n-pose.mlmodel` (classic NeuralNetwork backend) as a workaround. Now testing a FRESH
    // re-export, `yolo26n-pose 3.mlpackage` (see `modelName`) — still an ML Program model, so it's
    // NOT expected to sidestep the OS bug on principle (the bug lives in Core ML's own compiler
    // infrastructure, not in any particular model's content), but worth an honest test in case the
    // specific export settings that produced THIS package differ meaningfully from the original
    // one. Flip to `false` at any point to instantly fall back to Vision if this also hangs.
    static var useYOLO = false
}

/// Thin wrapper around the `UltralyticsYOLO` Swift package's `YOLO` class, scoped to exactly what
/// this app needs: run the bundled pose CoreML model (`modelName` below — currently a fresh
/// re-export, `yolo26n-pose 3.mlpackage`; see `PoseDetectionSettings.useYOLO`'s doc comment for
/// the full history of what's been tried) against a single frame and return its detected 2D body
/// keypoints, already mapped from COCO's 17-point layout into this app's own `BodyJointName` set
/// (`Core/Models.swift`). Every pose model tried so far (YOLO11, YOLO26) shares the same standard
/// COCO 17-keypoint output layout, and the `UltralyticsYOLO` package's `PoseEstimator`/
/// `BasePredictor` auto-detect NMS requirements from each model's own embedded metadata rather
/// than assuming one architecture — so nothing below this doc comment needs to change to support
/// a different model version, only `modelName`.
///
/// VERIFIED, NOT GUESSED: this file's API usage (`import UltralyticsYOLO`, `YOLO`'s
/// completion-handler-based init — NOT throwing, `callAsFunction(_:)` overloads, `YOLOResult
/// .keypointsList`, `Keypoints.xy`/`.xyn`/`.conf`) was checked directly against the actual source
/// of `YOLO.swift`/`YOLOResult.swift`/`YOLOTask.swift` at the exact commit this project's
/// `Package.resolved` is pinned to (`f34e3962f2e3f7905c7fcb79799c62d457b0a63b`), not assumed from
/// a hand-written example — a hand-written example for a fast-moving package is exactly the kind
/// of thing that goes stale, and this project has no compiler to catch a wrong guess.
///
/// COORDINATE SPACE NOTE: `detect(in:)`/`detect(in:)` feed the RAW, unrotated image straight into
/// `YOLO`'s `callAsFunction` (no orientation hint, unlike Vision's `cameraOrientation(for:)`
/// dance) — so the returned `.xy` pixel coordinates land in that SAME raw sensor coordinate space,
/// directly usable for LiDAR depth-buffer lookups with no extra rotation math (unlike Vision's
/// `rotateBearingToRawSensorFrame`). The tradeoff: YOLO's own detection quality may suffer on a
/// sideways/rotated raw frame, since pose models are generally trained on upright photos — if
/// on-device testing shows YOLO missing/misplacing joints because of this, the fix is to rotate
/// the image upright before calling `YOLO`, then rotate the returned points back to raw space
/// (mirroring `rotateBearingToRawSensorFrame`'s inverse, already derived for
/// `SkeletonImageOverlayView`) — deliberately not done upfront since it's real added complexity
/// that's only worth it if raw-frame accuracy actually turns out to be a problem.
enum YOLOBodyPoseDetector {
    /// One 2D-detected joint: its pixel location (in the SAME raw/native coordinate space the
    /// input image was given in) and Ultralytics' own per-keypoint confidence (0...1).
    struct DetectedJoint {
        let point: CGPoint
        let confidence: Float
    }

    enum DetectionError: Error, LocalizedError {
        case modelLoadFailed(Error)
        case unknownLoadFailure
        /// Carries `bundleResolutionDescription()`'s finding, taken at throw time, so the ON-SCREEN
        /// error message itself tells apart "resolution found a raw .mlpackage" (slow on-device
        /// compile, expected-if-annoying) from "resolution found an already-compiled .mlmodelc"
        /// (a timeout there means something deeper is stuck) — see that function's doc comment.
        case loadTimedOut(String)
        case noPersonDetected

        var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let error):
                return "YOLO model failed to load: \(error.localizedDescription)"
            case .unknownLoadFailure:
                return "YOLO model failed to load for an unknown reason (completion handler never fired)."
            case .loadTimedOut(let resolution):
                return "YOLO model load timed out after \(Int(modelLoadTimeoutSeconds))s. Bundle check: \(resolution)."
            case .noPersonDetected:
                return "No person detected."
            }
        }
    }

    /// Bundle resource name (no extension — `ModelPathResolver.resolve` looks for `.mlmodelc`
    /// then `.mlpackage` under this name; see `bundleResolutionDescription`). Currently
    /// `"yolo26n-pose 3"` — a fresh re-export the user added after the original `yolo26n-pose`
    /// export hit the iOS 26.4+ AOT-recompilation hang (see `PoseDetectionSettings.useYOLO`'s doc
    /// comment for the full history, including the `yolo11n-pose.mlmodel` legacy-format attempt).
    /// The space in the name is fine for `Bundle.main.url(forResource:withExtension:)` — it
    /// matches on the exact resource name, spaces included. Xcode compiles either an `.mlmodel`
    /// or an `.mlpackage` added to "Compile Sources" into a same-named `.mlmodelc` in the app
    /// bundle, so this lookup works identically regardless of which source format is in use; only
    /// this one string needs to change to switch which model actually loads.
    private static let modelName = "yolo26n-pose 3"

    /// Generous on purpose: an `.mlpackage` that Xcode compiled at build time loads fast (well
    /// under a second), but if it's still the RAW `.mlpackage` in the bundle (e.g. added as a
    /// "Copy Bundle Resources" member instead of "Compile Sources"), `MLModel.compileModel(at:)`
    /// does an on-device compile of the nano pose model on first load, which — on some
    /// device/OS combinations, especially a Debug build — can genuinely take tens of seconds. This
    /// exists to turn "the UI is stuck on 'Detecting pose…' forever with no way to tell why" into
    /// a bounded, diagnosable failure (`DetectionError.loadTimedOut`) instead of an infinite hang.
    /// Bumped well past a first observed 45s timeout (on real hardware, not a guess) specifically
    /// to find out whether this is "just needs more time" or a genuine hang — see
    /// `bundleResolutionDescription`, whose output is folded into the timeout error message so
    /// that distinction is visible without needing a console/Xcode attached.
    private static let modelLoadTimeoutSeconds: Double = 150

    /// Mirrors `ModelPathResolver.resolve`'s own bundle lookup (checked directly against that
    /// package's source — see this type's "VERIFIED, NOT GUESSED" doc comment) PURELY for
    /// diagnostics: telling apart "resolution never even found the model file" (near-instant
    /// failure, not a timeout — see `DetectionError.loadTimedOut`'s doc comment) from "resolution
    /// found the RAW, un-compiled `.mlpackage`" (forces a slow on-device compile on EVERY app
    /// launch, since only Xcode's own build-time compile output — `.mlmodelc` — persists; a raw
    /// `.mlpackage` in the bundle means that Xcode step never actually ran, e.g. wrong target
    /// membership) from "resolution found an already-compiled `.mlmodelc`" (should load in well
    /// under a second — a timeout here points at something deeper, e.g. a stuck on-device ANE
    /// compilation cache build for this specific model, not a resolution problem at all).
    private static func bundleResolutionDescription() -> String {
        if Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") != nil {
            return "found a pre-compiled \(modelName).mlmodelc in the app bundle (so a timeout here is NOT a resolution problem — something is stuck inside Core ML's own load/compile step)"
        }
        if Bundle.main.url(forResource: modelName, withExtension: "mlpackage") != nil {
            return "found only the RAW \(modelName).mlpackage in the app bundle, not a pre-compiled .mlmodelc — Xcode's build-time model compile never produced one, so this is doing a slow ON-DEVICE compile from scratch on every load; check the file's Xcode target membership is 'Compile Sources', not just 'Copy Bundle Resources'"
        }
        return "did NOT find \(modelName) as EITHER .mlmodelc or .mlpackage anywhere in the app bundle at all — should have failed near-instantly instead of timing out, so this points at something unexpected in bundle resolution itself"
    }

    private static let modelLock = NSLock()
    private static var cachedModel: YOLO?
    private static var loadError: Error?

    /// Dedicated queue for calling INTO this type — deliberately NOT `DispatchQueue.global(qos:
    /// .userInitiated)`. Root-caused on real hardware (iPhone 16 Pro Max, iOS 26.6 — modern,
    /// capable device, so this isn't a hardware/OS-compatibility limit): the `UltralyticsYOLO`
    /// package's own `BasePredictor.create` loads the Core ML model by dispatching its real work
    /// onto `DispatchQueue.global(qos: .userInitiated)` internally. Every caller of THIS type used
    /// to ALSO dispatch onto that exact same shared, global, system-wide queue before calling in
    /// here and then blocking synchronously on `loadedModel()`'s semaphore — meaning the blocked
    /// thread and the thread the package's own load needs were drawn from the SAME limited shared
    /// pool. Confirmed via a real device Console.app capture during a reproduced 150s timeout:
    /// ZERO Core ML / mediaserverd / ANE log activity of any kind for the entire window — exactly
    /// what a starved work item that never got to START looks like, as opposed to a genuinely slow
    /// or failing one (which would log something). Every call site that invokes anything in this
    /// file should dispatch through THIS queue instead of `.global(...)`, so the blocked thread
    /// can never be one the package's own loading work is competing for.
    static let queue = DispatchQueue(label: "com.sendsociety.climbcoach.yolo", qos: .userInitiated, attributes: .concurrent)

    /// Fire-and-forget warm-up: triggers the (potentially slow, first-time-only) model load on
    /// `queue` without any caller needing to wait for it — call this as soon as it's known YOLO
    /// will be needed (e.g. app launch, or whenever `PoseDetectionSettings.useYOLO` is flipped on)
    /// so the actual moment a coach hits Step 2/Step 4/a preview, the model is ALREADY loaded and
    /// `detect(in:)` returns fast. Doesn't fully eliminate the stall for Step 2's capture loop or
    /// Step 4's `generate()` — both currently call into this type synchronously ON THE MAIN THREAD
    /// (a separate, pre-existing pattern this file doesn't own) — but turns "block the main thread
    /// for however long the first load takes" into "block it for ~0ms because it's already done."
    static func preload() {
        queue.async {
            _ = try? loadedModel()
        }
    }

    /// Loads (once, cached) and runs the bundled pose model against `image`, returning every
    /// COCO joint YOLO found for the single highest-confidence detected person, mapped into
    /// `BodyJointName` — see `mapCOCOKeypoints` for exactly which joints get a clean 1:1 mapping,
    /// which get derived (root/centerShoulder as midpoints), and which get approximated
    /// (spine/centerHead/topHead).
    ///
    /// BLOCKS THE CALLING THREAD the first time this is called anywhere in the app (waiting for
    /// the CoreML model to finish loading/compiling — see `modelLoadTimeoutSeconds`). Callers MUST
    /// dispatch onto `queue` (never `DispatchQueue.global(...)` — see that property's doc comment)
    /// before calling in here; `SessionReviewView`'s skeleton preview does this correctly. Step 2's
    /// live capture loop and Step 4's `generate()` currently call in synchronously from the MAIN
    /// thread instead (a separate, pre-existing pattern) — see `preload()` for how to make that a
    /// non-issue in practice. Every call after the first returns immediately once the model is
    /// loaded.
    static func detect(in image: CGImage) throws -> [BodyJointName: DetectedJoint] {
        DebugLog.general.info("YOLO before detect model")
        let model = try loadedModel()
        DebugLog.general.info("YOLO detect(in: CGImage) starting inference")
        let result = try mapResult(model(image))
        DebugLog.general.info("YOLO detect(in: CGImage) finished — \(result.count, privacy: .public) joints")
        return result
    }

    /// Same as `detect(in:)`, for a live ARFrame's `capturedImage` — `CIImage(cvPixelBuffer:)` is
    /// a cheap, lazy wrapper (no upfront render, unlike converting to `CGImage` first first),
    /// matching how little extra work Step 2's already-tight ~15Hz live loop can afford.
    ///
    /// THIS is the overload Step 2 (`CalibrationFrameProcessor.processWithYOLO`) actually calls —
    /// `ARFrame.capturedImage` is a `CVPixelBuffer`, not a `CGImage`, so Swift's overload
    /// resolution picks THIS function, not `detect(in: CGImage)` above. A debug log placed in the
    /// CGImage overload will never fire from Step 2's call path regardless of whether/where
    /// anything hangs — it's simply the wrong overload for that caller.
    static func detect(in pixelBuffer: CVPixelBuffer) throws -> [BodyJointName: DetectedJoint] {
        DebugLog.general.info("YOLO detect(in: CVPixelBuffer) about to call loadedModel()")
        let model = try loadedModel()
        DebugLog.general.info("YOLO detect(in: CVPixelBuffer) starting inference")
        let result = try mapResult(model(CIImage(cvPixelBuffer: pixelBuffer)))
        DebugLog.general.info("YOLO detect(in: CVPixelBuffer) finished — \(result.count, privacy: .public) joints")
        return result
    }

    private static func loadedModel() throws -> YOLO {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let cachedModel, cachedModel.isLoaded {
            return cachedModel
        }
        if let loadError {
            throw DetectionError.modelLoadFailed(loadError)
        }

        // `YOLO`'s init is completion-handler based, not throwing/synchronous (see this type's
        // doc comment for why that matters — it's a real correction versus a naive `try YOLO(...)`
        // guess). A `DispatchSemaphore` bridges that into the synchronous call this wrapper
        // offers everywhere else in the app; `NSLock` above serializes concurrent callers so a
        // second caller waits for the FIRST load to finish rather than kicking off a redundant
        // second one.
        let resolution = bundleResolutionDescription()
        // `useGpu: false` — forces `computeUnits = .cpuOnly`. Kept off even though the earlier
        // test with the ORIGINAL `yolo26n-pose` export already showed `computeUnits` makes no
        // difference to the iOS 26.4+ AOT-recompilation hang (see `PoseDetectionSettings
        // .useYOLO`'s doc comment) — this is still an ML Program model, so that finding likely
        // still applies, but keeping it off costs nothing and rules out compute-unit selection as
        // a variable while testing whether THIS specific re-export behaves any differently.
        DebugLog.general.info("YOLO model load starting (\"\(modelName)\", task: .pose, useGpu: false) — bundle check: \(resolution, privacy: .public)")
        let semaphore = DispatchSemaphore(value: 0)
        var loadResult: Result<YOLO, Error>?
        _ = YOLO(modelName, task: .pose, useGpu: false) { result in
            loadResult = result
            semaphore.signal()
        }
        let waitOutcome = semaphore.wait(timeout: .now() + modelLoadTimeoutSeconds)

        guard waitOutcome == .success else {
            // Deliberately NOT cached into `loadError` — a slow-but-eventually-successful load
            // (e.g. a one-time on-device compile) shouldn't be permanently poisoned by one timeout;
            // the NEXT call gets a fresh attempt. If the underlying `YOLO(...)` completion fires
            // AFTER this point, it just sets `loadResult`/signals into a semaphore nothing is
            // waiting on anymore — harmless, not a leak (the closure captures no `self`).
            DebugLog.general.error("YOLO model load timed out after \(modelLoadTimeoutSeconds, privacy: .public)s — bundle check: \(resolution, privacy: .public)")
            throw DetectionError.loadTimedOut(resolution)
        }

        switch loadResult {
        case .success(let model):
            DebugLog.general.info("YOLO model loaded successfully")
            cachedModel = model
            return model
        case .failure(let error):
            DebugLog.general.error("YOLO model load failed: \(String(describing: error), privacy: .public)")
            loadError = error
            throw DetectionError.modelLoadFailed(error)
        case nil:
            throw DetectionError.unknownLoadFailure
        }
    }

    private static func mapResult(_ result: YOLOResult) throws -> [BodyJointName: DetectedJoint] {
        // Multiple people can appear in `keypointsList` — pick the one with the highest AVERAGE
        // per-keypoint confidence rather than assuming index 0 is already confidence-sorted (not
        // documented behavior of the package, so not something to rely on blind).
        guard let best = result.keypointsList.max(by: { averageConfidence($0) < averageConfidence($1) }) else {
            throw DetectionError.noPersonDetected
        }
        return mapCOCOKeypoints(best)
    }

    private static func averageConfidence(_ keypoints: Keypoints) -> Float {
        guard !keypoints.conf.isEmpty else { return 0 }
        return keypoints.conf.reduce(0, +) / Float(keypoints.conf.count)
    }

    /// Standard COCO 17-keypoint order (index -> joint) — the same order Ultralytics' own
    /// training data and every exported pose model, including `yolo11n-pose`, uses: 0 nose,
    /// 1 left_eye, 2 right_eye, 3 left_ear, 4 right_ear, 5 left_shoulder, 6 right_shoulder,
    /// 7 left_elbow, 8 right_elbow, 9 left_wrist, 10 right_wrist, 11 left_hip, 12 right_hip,
    /// 13 left_knee, 14 right_knee, 15 left_ankle, 16 right_ankle.
    ///
    /// Twelve of `BodyJointName`'s 17 cases map 1:1 (both shoulders/elbows/wrists/hips/knees/
    /// ankles). `root` and `centerShoulder` are derived as the midpoint of the matching L/R pair
    /// — standard practice, matches what Apple's own `VNDetectHumanBodyPose3DRequest` effectively
    /// exposes anyway. `spine`, `centerHead`, and `topHead` have NO COCO source at all — COCO's
    /// `nose` is a face landmark, not the same anatomical point as Apple's skull-center/top
    /// landmarks — so these three are explicit, product-decided approximations, not
    /// measurements: `spine` = midpoint(root, centerShoulder); `centerHead`/`topHead` are
    /// extrapolated further upward along the centerShoulder->nose direction, continuing past the
    /// nose, using that distance as a rough head-size proxy. Confidence for every
    /// derived/approximated joint is explicitly reduced (minimum of its real inputs for
    /// derived ones, halved for the head guesses) so a shaky derivation reads as low-confidence
    /// downstream rather than borrowing an unrelated point's high confidence.
    private static func mapCOCOKeypoints(_ keypoints: Keypoints) -> [BodyJointName: DetectedJoint] {
        func point(_ index: Int) -> CGPoint? {
            guard index < keypoints.xy.count else { return nil }
            let p = keypoints.xy[index]
            return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        }
        func confidence(_ index: Int) -> Float {
            guard index < keypoints.conf.count else { return 0 }
            return keypoints.conf[index]
        }
        func midpoint(_ a: Int, _ b: Int) -> DetectedJoint? {
            guard let pa = point(a), let pb = point(b) else { return nil }
            let mid = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
            return DetectedJoint(point: mid, confidence: min(confidence(a), confidence(b)))
        }

        var joints: [BodyJointName: DetectedJoint] = [:]
        let directMapping: [(Int, BodyJointName)] = [
            (5, .leftShoulder), (6, .rightShoulder),
            (7, .leftElbow), (8, .rightElbow),
            (9, .leftWrist), (10, .rightWrist),
            (11, .leftHip), (12, .rightHip),
            (13, .leftKnee), (14, .rightKnee),
            (15, .leftAnkle), (16, .rightAnkle),
        ]
        for (index, joint) in directMapping {
            if let p = point(index) {
                joints[joint] = DetectedJoint(point: p, confidence: confidence(index))
            }
        }

        if let root = midpoint(11, 12) { joints[.root] = root }
        if let centerShoulder = midpoint(5, 6) { joints[.centerShoulder] = centerShoulder }
        if let root = joints[.root], let centerShoulder = joints[.centerShoulder] {
            joints[.spine] = DetectedJoint(
                point: CGPoint(
                    x: (root.point.x + centerShoulder.point.x) / 2,
                    y: (root.point.y + centerShoulder.point.y) / 2
                ),
                confidence: min(root.confidence, centerShoulder.confidence)
            )
        }
        if let nose = point(0), let centerShoulder = joints[.centerShoulder] {
            let headDirectionX = nose.x - centerShoulder.point.x
            let headDirectionY = nose.y - centerShoulder.point.y
            let noseConfidence = confidence(0)
            joints[.centerHead] = DetectedJoint(
                point: CGPoint(x: nose.x + headDirectionX * 0.15, y: nose.y + headDirectionY * 0.15),
                confidence: noseConfidence * 0.5
            )
            joints[.topHead] = DetectedJoint(
                point: CGPoint(x: nose.x + headDirectionX * 0.35, y: nose.y + headDirectionY * 0.35),
                confidence: noseConfidence * 0.5
            )
        }
        return joints
    }
}

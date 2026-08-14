# Send Society — Project Structure Reference

This is a navigation map of the app, built by reading every file's doc comments and declarations.
Use it to find "where does X live" without re-browsing the whole project. When rebuilding from
zero, work through the **Suggested Build Order** at the bottom, block by block.

---

## 1. What the app does

A LiDAR climbing-coach app for iPad. A coach scans a climbing wall, records the climber's attempt
on video (with live depth data), then generates a static 3D skeleton pose placed against the
scanned wall — so the climber's body position can be reviewed and annotated after the fact.
Sessions are saved and can be reopened later from a library list.

Pipeline: **scan the wall → record the climb → pick a moment → generate a 3D pose → annotate/save**.

## 2. Big-picture architecture

Three top-level folders:

- **`Core/`** — plain Swift only. No SwiftUI anywhere in this folder. Split into four modules:
  `Capture` (getting real-world data in), `PoseReconstruction` (the actual climbing-analysis
  algorithm), `Persistence` (saving/loading to disk), plus a few root-level small utilities
  (`Models.swift`, `DebugLog.swift`, `DeveloperSettings.swift`, `LiDARSupport.swift`,
  `UserIdentity.swift`).
- **`Features/`** — SwiftUI screens, one subfolder per screen area: `Onboarding`, `Recording`,
  `Library`, `Reconstruction`, plus `Shared` for small pieces reused across screens.
- **Root** — `ContentView.swift` (the record→reconstruct pipeline coordinator) and
  `SendSocietyApp.swift` (the `@main` entry point).

**The Engine/View split** (applies to every screen under `Features/*/Pages/`): each screen is a
PAIR of files — `SomethingEngine.swift` (a plain class/struct/enum, `import Foundation` only, no
SwiftUI — holds all the actual logic/decisions) and `SomethingView.swift` (SwiftUI, UI-only,
calls into the Engine for every decision instead of embedding logic itself). This means a
front-end redesign only ever needs to touch the View file; the Engine file underneath never
changes. `RecordingEngine`/`RecordingView`, `PlaybackEngine`/`PlaybackView`,
`LibraryEngine`/`LibraryView`, `SessionReviewEngine`/`SessionReviewView`,
`ReconstructionHostEngine` (paired with `ContentView`'s private `ReconstructionHost`) all follow
this pattern.

**`@MainActor` rule:** `SessionStore` (in `Core/Persistence`) is the only `@MainActor`-isolated
type in the whole app (SwiftData's `ModelContext` isn't safe off the main thread). Any Engine
type that calls a `SessionStore` method (`.save()`, `.fetchAll()`, `.delete()`) must itself be
marked `@MainActor`. SwiftUI `View` structs get this for free (protocol-conformance global-actor
inference), so plain Views calling `sessionStore.save()` inline never need the annotation — only
plain Engine classes/structs/enums do.

## 3. App entry & navigation flow

```
SendSocietyApp (@main)
  └─ LibraryView                              ← actual app root, shown first
       ├─ "New Recording" → ContentView         (full-screen pipeline)
       │    ├─ step = .recording → RecordingView → (stop) → PlaybackView
       │    │                                              (same screen, shows recorded clip)
       │    │        PlaybackView "Generate 3D" → step = .reconstruction
       │    └─ step = .reconstruction → ReconstructionHost (private, in ContentView.swift)
       │         └─ ReconstructionView (+ ReconstructionSceneView for the RealityKit scene)
       │              "Done" → onFinished() → back to LibraryView
       └─ tap a saved session row → SessionReviewView
            ├─ scrubber marker w/ saved 3D pose → SavedReconstructionReviewView
            └─ "Estimate 3D View" (no live AR) → SessionReviewEngine.generateEstimate(...)
```

Onboarding screens (`InitialScreen`, `Tutorial1`/`Tutorial2`/`Tutorial3`, `TutorialOne`) exist as
files but are **not wired into `SendSocietyApp`** — the app launches straight into `LibraryView`.
Treat them as unused/future work unless you wire them in yourself.

## 4. Full file map

### Core/ (plain Swift, no SwiftUI)

| File | Lines | What it's for |
|---|---|---|
| `Core/Models.swift` | 116 | Shared plain data types used everywhere: `AppStep` (recording/reconstruction), `TrackingQuality`, `BodyJointName` (the skeleton joint enum), `SkeletonBone`, `AnnotationTool`, `AnnotationStroke`. |
| `Core/DebugLog.swift` | 18 | OSLog categories, one per MVP success criterion (recording / reconstruction / tracking / general), so device console logs can be filtered per-question. |
| `Core/DeveloperSettings.swift` | 21 | Tiny UserDefaults-backed dev-only toggles (e.g. "show raw LiDAR mesh"), not a real settings screen. |
| `Core/LiDARSupport.swift` | 10 | One check: does this device support scene reconstruction at all. |
| `Core/UserIdentity.swift` | 39 | Local guest user ID (`UUID`), stamped on every saved session. No real login yet; designed so a future login can "claim" this same ID. |
| `Core/Capture/ARSessionManager.swift` | 282 | Owns the single shared `ARSession` (one instance across the whole record pipeline — never restarted, or wall/body coordinate spaces drift apart). Publishes `trackingQuality`, `meshAnchors`, `latestFrame`, `wallTextureReference`. Also: `captureWallTextureReference()` (freezes a color+depth reference frame + mesh snapshot when wall scanning is marked done), `depthConfidenceRatio(for:)` (live per-frame "how much of this view has confident depth" 0...1), private `averageConfidentDepth(depthMap:confidenceMap:)` (pixel-math average depth in meters). |
| `Core/Capture/VideoRecorder.swift` | 247 | Records ARKit camera frames to `.mp4` via `AVAssetWriter`; simultaneously feeds each frame to `RecordedFrameStore` keyed by ARKit timestamp, so a paused video position can be traced back to matching depth/camera data. |
| `Core/Capture/RecordedFrameStore.swift` | 136 | In-memory store of per-frame camera transform + depth data captured during recording; `nearestFrame(toPlaybackSeconds:)` looks one up by paused video time. |
| `Core/Capture/PixelBufferCopy.swift` | 44 | One helper: deep-copy a `CVPixelBuffer` (ARKit buffers are pool-reused and unsafe to hold onto raw). |
| `Core/Capture/VideoFrameExtractor.swift` | 35 | Pulls a single still frame out of a saved `.mp4` at an arbitrary timestamp — used by session review's "Estimate 3D" path. |
| `Core/Capture/DeviceDiagnostics.swift` | 45 | Lightweight memory/thermal readouts for diagnosing crashes during the heaviest workload (recording). |
| `Core/Persistence/SessionStore.swift` | 125 | **The only front door to persistence.** Every screen creates/reads/updates/deletes a `RecordingSession` through this — never through `SessionFileStore`/`WallScanArchive` directly. `@MainActor`. Functions: `createSession(...)`, `fetchAll()`, `delete(_:)`, `save()`, `wallTextureReference(for:)`, `videoURL(for:)`. |
| `Core/Persistence/RecordingSession.swift` | 215 | The one SwiftData `@Model` class. Child data (video annotations, 3D reconstructions) stored as JSON blobs on this single model rather than separate related models (deliberate — simpler, lower-risk without a compiler). Also defines `VideoAnnotationEntry` and `ReconstructionEntry`. |
| `Core/Persistence/SessionFileStore.swift` | 73 | Implementation detail of `SessionStore` — resolves filenames/folder names stored on `RecordingSession` into actual file paths (Application Support directory, not Documents). |
| `Core/Persistence/WallScanArchive.swift` | 327 | Implementation detail of `SessionStore` — saves/loads an `ARSessionManager.WallTextureReference` to/from disk (color image, depth grid, confidence grid, camera pose) so a wall scan survives after the live AR session ends. **Flagged as the highest-risk file in the codebase** (raw `CVPixelBuffer` packing/unpacking, unverified on device). |
| `Core/Persistence/CodableSIMD.swift` | 84 | Retroactive `Codable` conformance for `SIMD3<Float>`, `SIMD4`, `simd_float3x3`, `simd_float4x4` — needed once, centrally, so every domain struct containing one of these can just add `: Codable`. |
| `Core/PoseReconstruction/BodyPose3DExtractor.swift` | 909 | **The Vision detection core.** Runs `VNDetectHumanBodyPose3DRequest`, defines `BodyPoseSample` (raw Vision output) and `DepthGroundingContext`. Key functions: `detect(inVideoFrame:deviceOrientation:)`, `groundSkeletonRootAnchored(...)` (the LiDAR-grounded, high-accuracy path), `worldPosition(rootRelative:cameraOriginMatrix:cameraTransform:)` (Vision-only fallback path, lower accuracy), `projected2DImagePoints(...)` (for 2D skeleton preview overlays). |
| `Core/PoseReconstruction/ReconstructionEntityBuilder.swift` | 731 | **The RealityKit geometry builder.** Turns wall mesh anchors + a `BodyPoseSample`/`worldPositions` into actual renderable `Entity` objects: `wallEntity(...)`, `pointCloudWallEntity(...)` (bump-detailed textured wall from raw depth), `skeletonEntity(...)` (both the thin red skeleton and the tan mannequin body, sharing one `cylinderBetween` helper), `worldJointPositions(...)`. |
| `Core/PoseReconstruction/LiveReconstructionGenerator.swift` | 133 | Runs the full **live** Step-4 pipeline for one paused video moment: real recorded LiDAR depth + camera pose (from `RecordedFrameStore`) + Vision detection, all the way to grounded world positions. This is the higher-accuracy path (vs. `ReconstructionEstimator`). |
| `Core/PoseReconstruction/ReconstructionEstimator.swift` | 105 | Builds a `ReconstructionEntry` from a saved video frame **without** live LiDAR depth — the "Estimate 3D" path used from session review, when the original recording never had depth data saved for that exact moment. Lower accuracy, entries flagged `isApproximate`. |
| `Core/PoseReconstruction/SkeletonPoseEditor.swift` | 221 | Manual joint-drag math with anatomical constraints (cone/hinge angle clamps per joint, real clinical ROM figures) — keeps a coach's manual joint correction anatomically plausible. Pure math, no RealityKit dependency. |
| `Core/PoseReconstruction/JointDragProjector.swift` | 30 | Pure "unproject a 2D screen touch into a 3D drag" math, pulled out of `ReconstructionSceneView`'s gesture coordinator. |
| `Core/PoseReconstruction/PersonPresenceDetector.swift` | 53 | Lightweight "is anyone in this shot" check (`VNDetectHumanRectanglesRequest`, not the heavy 3D pose request) — used to skip auto-saving a wall reference frame that has a person standing in it. |

### Features/ (SwiftUI)

| File | Lines | What it's for |
|---|---|---|
| `Features/Recording/Pages/RecordingEngine.swift` | 107 | Engine for Step 2. Owns two repeating timers: depth-quality polling (`depthQuality`, `isReadyToRecord`) and periodic person-gated wall-mesh auto-save (`wallSaveLogLines`, `attemptWallMeshSave()`). |
| `Features/Recording/Pages/RecordingView.swift` | 183 | View for Step 2. "Point at the Wall" screen — live AR mesh view, readiness guidance text, record button. Hands off to `PlaybackView` once a clip exists. |
| `Features/Recording/Pages/PlaybackEngine.swift` | 125 | Engine for the video-review screen. Defines `VideoMarkerModel`. Functions: `findDrawing(nearVideoTime:)`, `saveDrawing(_:atVideoTime:)`, `allSavedMoments()` (merges saved drawings + saved 3D poses into one scrubber marker list). |
| `Features/Recording/Pages/PlaybackView.swift` | 259 | View for the video-review screen shown right after recording stops. Scrubber with tappable markers, drawing overlay, "Generate 3D" button. |
| `Features/Library/Pages/LibraryEngine.swift` | 31 | Engine for the library list. Three functions wrapping `SessionStore`: `loadAllSessions()`, `sessions(_:matching:)` (search filter), `deleteSession(_:)`. |
| `Features/Library/Pages/LibraryView.swift` | 184 | **App's actual root screen.** Chronological session list + "New Recording" entry point into `ContentView`. |
| `Features/Library/Components/SessionRow.swift` | 54 | One row in the library list: title, relative date, duration, reconstruction-count badge. |
| `Features/Library/Pages/SessionReviewEngine.swift` | 156 | Engine for reopening a saved session. Defines `SkeletonPreviewResult`, `SkeletonPreviewFailure` (Error wrapper). Functions: `reconstruction(nearVideoTime:)`, `deleteReconstruction(_:)`, `generateEstimate(...)` (real save), `generateSkeletonPreview(...)` (disposable sanity-check overlay, nothing saved). `@MainActor`. |
| `Features/Library/Pages/SessionReviewView.swift` | 485 | View for reopening a saved session — video playback with saved drawings, scrubber markers, "Estimate 3D View", "Preview Skeleton" toggle. |
| `Features/Library/Pages/SavedReconstructionReviewView.swift` | 89 | Renders one already-saved `ReconstructionEntry` directly (no Vision, no live AR session) — reuses `ReconstructionView`'s "load existing pose" path. |
| `Features/Reconstruction/Pages/ReconstructionHostEngine.swift` | 134 | Engine for Step 4's first-frame decision. Defines `ReconstructionResult`. Functions: `loadOrGenerate(input:session:wallReference:)` (load a nearby saved pose, or run `LiveReconstructionGenerator` fresh), `save(...)`. `@MainActor`. |
| `Features/Reconstruction/Pages/ReconstructionView.swift` | 323 | View for Step 4 — the non-AR RealityKit scene (wall + skeleton), mode controls (view/edit-pose/annotate), reset pose, banners. |
| `Features/Reconstruction/Components/ReconstructionSceneView.swift` | 603 | The actual RealityKit rendering + gesture surface (`UIViewRepresentable`) behind `ReconstructionView` — orbit camera, pinch-zoom, joint-drag hit-testing via its `Coordinator`. **Deliberately left untouched during the app-wide simplification pass** — large, recently-tested gesture state machine. |
| `Features/Onboarding/InitialScreen.swift`, `Tutorial1.swift`, `Tutorial2.swift`, `Tutorial3.swift`, `TutorialOne.swift` | ~40-50 each | Onboarding screens. **Not wired into the app** (`SendSocietyApp` launches straight into `LibraryView`). Known bugs left as-is: `Tutorial2`/`Tutorial3` both reference image `"Tutorial1"`; `Tutorial3`'s button has an empty action. |
| `Features/Shared/Components/PlaybackModel.swift` | 55 | Thin `AVPlayer` wrapper (`@Published` play/pause/current time) shared between `PlaybackView` and `SessionReviewView`. |
| `Features/Shared/Components/AnnotationOverlay.swift` | 241 | Screen-space drawing surface (pen/line/angle tools) drawn on top of the 3D view. Defines `AnnotationState` (shared `ObservableObject`) and `AnnotationToolbar`. |
| `Features/Shared/Components/ARMeshSceneView.swift` | 42 | Thin `UIViewRepresentable` wrapper around a live-passthrough RealityKit `ARView`, attached to the shared `ARSessionManager` session — used by `RecordingView`. |
| `Features/Shared/Components/MeshToggleButton.swift` | 29 | Small button toggling the live LiDAR mesh wireframe on/off, backed by `DeveloperSettings.showMesh`. |
| `Features/Shared/Components/SkeletonImageOverlayView.swift` | 127 | Draws Vision's raw 2D detected skeleton on top of a single still frame — the "Preview Skeleton" sanity check before running a full 3D generate/estimate. |

### Root

| File | Lines | What it's for |
|---|---|---|
| `SendSocietyApp.swift` | 26 | `@main` entry point. Registers the SwiftData model container for `RecordingSession.self`. Shows `LibraryView` as the root. |
| `ContentView.swift` | 238 | Root of the record→reconstruct pipeline (reached from `LibraryView`'s "New Recording"). Owns the single shared `ARSessionManager` + `VideoRecorder` for the pipeline's lifetime, switches between `.recording`/`.reconstruction` via `AppStep`, creates the `RecordingSession` the moment recording finishes (`createSessionIfNeeded`). Also defines `ReconstructionInput` (Step 3→4 handoff data) and the private `ReconstructionHost` view (wraps `ReconstructionHostEngine`). |

## 5. Persistence flow, in one paragraph

Every screen talks to `SessionStore` only (never `SessionFileStore`/`WallScanArchive` directly —
those are private implementation details by convention, not by compiler enforcement, since this
is a single app target). `SessionStore` reads/writes the one SwiftData `@Model`,
`RecordingSession`, whose big binary data (video file, archived wall scan) lives on disk as
separate files referenced by filename/folder name — not stored as SwiftData blobs themselves.
Per-timestamp video annotations and 3D reconstructions are stored as JSON `Data` blobs directly on
`RecordingSession` (not as separate related `@Model` types) to avoid depending on SwiftData
relationship macros that couldn't be verified without a compiler.

## 6. Xcode project registration (manual file-by-file build only)

Every new `.swift` file needs 4 correlated entries added to `SendSociety.xcodeproj/project.pbxproj`:
a `PBXBuildFile` entry, a `PBXFileReference` entry, an entry in the right group's `children` array,
and an entry in the `PBXSourcesBuildPhase` `files` array — each new file needs a fresh 24-character
uppercase hex ID (e.g. via `python3 -c "import secrets; print(secrets.token_hex(12).upper())"`).
If you're adding files through Xcode itself (dragging a new file into the navigator), Xcode does
this automatically — this only matters if a file is created outside Xcode and needs registering by
hand.

## 7. Suggested build order, block by block

Build in this order so each block only depends on blocks already built. Test/compile after every
block before moving to the next.

**Block 1 — Foundation (no UI, nothing depends on anything else yet)**
`Core/Models.swift`, `Core/DebugLog.swift`, `Core/DeveloperSettings.swift`, `Core/LiDARSupport.swift`,
`Core/UserIdentity.swift`, `Core/Persistence/CodableSIMD.swift`.

**Block 2 — Persistence**
`Core/Persistence/RecordingSession.swift` → `Core/Persistence/SessionFileStore.swift` →
`Core/Persistence/WallScanArchive.swift` → `Core/Persistence/SessionStore.swift`.
(`SessionStore` depends on all three of the others.)

**Block 3 — Capture (getting AR/video data)**
`Core/Capture/PixelBufferCopy.swift`, `Core/Capture/DeviceDiagnostics.swift` → 
`Core/Capture/ARSessionManager.swift` (needs `WallScanArchive`'s type shape for `WallTextureReference`,
though not a direct import) → `Core/Capture/RecordedFrameStore.swift` →
`Core/Capture/VideoRecorder.swift` → `Core/Capture/VideoFrameExtractor.swift`.

**Block 4 — Minimal end-to-end skeleton (get something on screen)**
`SendSocietyApp.swift` → a trivial placeholder `ContentView.swift`/`LibraryView.swift` just to
confirm the SwiftData container + navigation shell boots.

**Block 5 — Recording screen**
`Features/Recording/Pages/RecordingEngine.swift` → `Features/Shared/Components/ARMeshSceneView.swift` →
`Features/Shared/Components/MeshToggleButton.swift` → `Features/Recording/Pages/RecordingView.swift`.
Needs Block 3 (ARSessionManager, VideoRecorder) + Block 1 (DeveloperSettings).

**Block 6 — Playback screen**
`Features/Shared/Components/PlaybackModel.swift` → `Features/Shared/Components/AnnotationOverlay.swift` →
`Features/Recording/Pages/PlaybackEngine.swift` → `Features/Recording/Pages/PlaybackView.swift`.
Needs Block 2 (SessionStore/RecordingSession) + Block 1 (AnnotationStroke).

**Block 7 — Pose reconstruction algorithm (still no UI)**
`Core/PoseReconstruction/PersonPresenceDetector.swift` → `Core/PoseReconstruction/BodyPose3DExtractor.swift`
(the big one — build/test in isolated pieces if possible: `detect`, then `groundSkeletonRootAnchored`,
then the fallback `worldPosition`) → `Core/PoseReconstruction/JointDragProjector.swift` →
`Core/PoseReconstruction/SkeletonPoseEditor.swift` → `Core/PoseReconstruction/ReconstructionEntityBuilder.swift` →
`Core/PoseReconstruction/LiveReconstructionGenerator.swift` → `Core/PoseReconstruction/ReconstructionEstimator.swift`.

**Block 8 — Reconstruction screen**
`Features/Reconstruction/Pages/ReconstructionHostEngine.swift` →
`Features/Reconstruction/Components/ReconstructionSceneView.swift` →
`Features/Reconstruction/Pages/ReconstructionView.swift`.
Needs Block 7 in full.

**Block 9 — Wire the pipeline together**
`ContentView.swift` for real (replacing the Block 4 placeholder) — owns `ARSessionManager`/
`VideoRecorder`, switches `RecordingView` ↔ `ReconstructionHost`/`ReconstructionView`, creates the
`RecordingSession` on recording-stop.

**Block 10 — Library / session review**
`Features/Library/Components/SessionRow.swift` → `Features/Library/Pages/LibraryEngine.swift` →
`Features/Library/Pages/LibraryView.swift` (now the real app root — update `SendSocietyApp.swift`) →
`Features/Shared/Components/SkeletonImageOverlayView.swift` →
`Features/Library/Pages/SessionReviewEngine.swift` → `Features/Library/Pages/SessionReviewView.swift` →
`Features/Library/Pages/SavedReconstructionReviewView.swift`.

**Block 11 — Onboarding (optional / currently unused)**
`Features/Onboarding/*.swift` — build last, wire into `SendSocietyApp` only if/when you actually
want an onboarding flow; the rest of the app doesn't depend on it.

---

*When asking "how do I build X," name the screen/file and I'll pull the exact section above plus
read the current file(s) fresh — this doc is a map, not a substitute for reading real code before
editing it.*

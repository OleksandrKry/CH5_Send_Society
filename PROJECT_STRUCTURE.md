# Send Society — Project Structure Reference

This is a navigation map of the app, built by reading every file's doc comments and declarations.
Use it to find "where does X live" without re-browsing the whole project. When rebuilding from
zero, work through the **Suggested Build Order** at the bottom, block by block.

*Last synced to the codebase on 2026-08-18, after a structural migration (Core/Persistence split
into Core/ModelDB + Core/Persistence, Features/Shared renamed to Features/Commons, the
recording/reconstruction pipeline rewritten around `RecordingSessionV2`/`VideoAttemptV2`/
`Climber`). If the file tree has moved again since, treat this doc as stale and re-derive it.*

---

## 1. What the app does

A LiDAR climbing-coach app for iPad. A coach starts a recording session for one climber/route,
records one or more attempts on video (against a wall that's scanned live, in the background,
before the first clip), then generates a static 3D skeleton pose for any moment in a clip —
placed against the scanned wall — so the climber's body position can be reviewed and annotated.
Sessions (and every clip/pose/drawing in them) are saved and can be reopened later from a library
list that's searchable and filterable by climber.

Pipeline: **pick a climber & route grade → record one or more climbing attempts (wall scan happens
automatically in the background) → scrub a clip, pick a moment → generate a 3D pose → edit the
pose / annotate → revisit anytime from the Library**.

## 2. Big-picture architecture

Three top-level code folders, plus non-code `Assets/`/`Resources/`:

- **`Core/`** — plain Swift only. No SwiftUI anywhere in this folder. Split into four modules:
  - `Capture` — getting real-world data in (ARKit session, video recording, per-frame depth store).
  - `PoseReconstruction` — the actual climbing-analysis algorithm (Vision detection, LiDAR
    grounding, RealityKit geometry building, manual joint editing).
  - `ModelDB` — every plain data type/model (`RecordingSessionV2`, `VideoAttemptV2`, `Climber`,
    `RouteGrade`, the shared enums, `CodableSIMD`), PLUS two disk-I/O implementation details
    (`SessionFileStore`, `WallScanArchive`) that live here despite not being "models" — see
    §4 for why.
  - `Persistence` — now just the one real front-door type, `SessionStoreV2` (plus an empty,
    unused stub — see §4).
  - a few root-level small utilities: `DebugLog.swift`, `DeveloperSettings.swift`,
    `LiDARSupport.swift`, `UserIdentity.swift`.
- **`Features/`** — SwiftUI screens, one subfolder per screen area: `Onboarding`, `Recording`,
  `Library`, `Reconstruction`, plus `Commons` for small pieces reused across screens (renamed
  from the old `Shared`).
- **Root** — `ContentView.swift` (gates on climber/route-grade selection, then hosts the
  recording screen) and `SendSocietyApp.swift` (the `@main` entry point).
- **`Assets/`, `Resources/`** — non-code. `Resources/Assets.xcassets` holds the app's color
  assets (`primaryBlue`, `primaryDark`, `primaryLightLessOpacity`, `annotateRed`/`Green`/
  `Blue`/`Yellow`, etc. — used throughout the Recording/Reconstruction UI) and image assets;
  `Resources/Info.plist` is the app's plist. `Assets/Tutorial1.png` is a loose duplicate of the
  same image already inside `Resources/Assets.xcassets/Tutorial1.imageset/` — likely a leftover,
  not something anything code-level depends on directly (SwiftUI's `Image("Tutorial1")` resolves
  from the asset catalog, not this loose file).

**The Engine/View split** still holds for most screens under `Features/*/Pages/`, though it's no
longer perfectly 1:1 everywhere post-migration:
- `RecordingEngineV2`/`RecordingViewV2`, `LibraryEngine`/`LibraryView` are still a clean pair.
- `PlaybackEngine` (plain logic, no SwiftUI) is now **shared** by two Views —
  `PlaybackViewV2` (in-session review) and `OfflinePlaybackView` (Library review) — rather than
  owned by just one.
- `Generate3DEngine` (replaces the old `ReconstructionHostEngine`) is a `@MainActor` enum of
  static functions, called from two different coordinator views (`PlaybackLayerV2` and
  `OfflinePlaybackLayer`) rather than paired with a single View.
- `Skeleton3DView`'s actual gesture/rendering "engine" is `Skeleton3DSceneView` — a
  `UIViewRepresentable` + `Coordinator` (RealityKit scene, orbit/pan/zoom, joint-drag and
  whole-body-drag gesture state machine), the same role the old `ReconstructionSceneView` played.
  This is still the file to treat as its own self-contained unit rather than folding into
  `Skeleton3DView` — it has grown, not shrunk (now handles per-axis drag handles and a
  whole-body translate handle in addition to plain joint dragging).
- `PlaybackLayerV2`/`OfflinePlaybackLayer` are coordinator views (not "Engines") that toggle
  between a 2D playback View and `Skeleton3DView`, similar to the role `ContentView`'s old
  `ReconstructionHost` used to play, but now scoped per-video-attempt.

**`@MainActor` rule:** `SessionStoreV2` (`Core/Persistence`) is still the one type wrapping
SwiftData's `ModelContext` (not safe off the main thread), but it's no longer the *only*
`@MainActor` type — two more got added as part of the migration because they call into it:
`LibraryEngine` (`@MainActor struct`) and `Generate3DEngine` (`@MainActor enum`). Any new Engine
type that calls a `SessionStoreV2` method must be `@MainActor` too, same rule as before; plain
SwiftUI `View` structs still get this for free.

## 3. App entry & navigation flow

```
SendSocietyApp (@main)
  └─ LibraryView                                     ← actual app root, shown first
       ├─ "New Recording" → ContentView                (full-screen)
       │    ├─ no climber/route picked yet → RecordingClimberView
       │    │      (pick RouteGrade + Climber — creates a new Climber row if needed)
       │    └─ climber+grade picked → RecordingViewV2
       │           (ONE continuous screen for the whole session: live AR mesh view, wall
       │            reference auto-saved in the background — only BEFORE the first
       │            recording — record button, thumbnail row of every clip taken so far)
       │           tap a thumbnail → PlaybackLayerV2 (overlay)
       │                ├─ PlaybackViewV2 (2D scrub/annotate the just-recorded clip)
       │                │       "Generate 3D" → Generate3DEngine.loadOrGenerate (live LiDAR path)
       │                └─ Skeleton3DView (+ Skeleton3DSceneView for the RealityKit scene)
       │                       "Back to video" / "Done" → back to PlaybackViewV2
       │           "End Session" → onSessionDone() → back to LibraryView
       └─ tap a saved video-attempt row → OfflinePlaybackLayer (full-screen)
            ├─ OfflinePlaybackView (2D scrub/annotate, no live AR session)
            │       "Generate 3D" → loads a saved pose if one exists nearby, else
            │       AppleVisionEstimator.estimate(...) (no live LiDAR depth — Vision-only)
            └─ Skeleton3DView (same component as the live path, fed offline data)
```

`LibraryView`'s list is **every recorded video attempt across every session**, flattened and
sorted newest-first (not one row per session) — see `LibraryEngine.loadAllVideoAttempts()`. It's
filterable by a `Climber` picker at the top and by the search field (matches session title).

There is no `AppStep`/step-machine enum anymore (the old `.recording`/`.reconstruction` switch on
`ContentView` is gone) — `ContentView` now just gates on "do we have a climber + route grade yet,"
and `RecordingViewV2` itself owns showing/hiding the playback overlay for whichever clip is
selected.

Onboarding screens (`InitialScreen`, `Tutorial1`/`Tutorial2`/`Tutorial3`, `TutorialOne`) exist as
files but are **still not wired into `SendSocietyApp`** — the app launches straight into
`LibraryView`. Known bugs left as-is: `Tutorial2`/`Tutorial3` both reference image `"Tutorial1"`;
`Tutorial3`'s button has an empty action.

## 4. Full file map

### Core/ (plain Swift, no SwiftUI)

| File | Lines | What it's for |
|---|---|---|
| `Core/DebugLog.swift` | 18 | OSLog categories, one per MVP success criterion (recording / reconstruction / tracking / general), so device console logs can be filtered per-question. |
| `Core/DeveloperSettings.swift` | 21 | Tiny UserDefaults-backed dev-only toggles (e.g. "show raw LiDAR mesh"), not a real settings screen. |
| `Core/LiDARSupport.swift` | 10 | One check: does this device support scene reconstruction at all. |
| `Core/UserIdentity.swift` | 39 | Local guest user ID (`UUID`), stamped on every saved session/climber. No real login yet; designed so a future login can "claim" this same ID. |
| `Core/Capture/ARSessionManager.swift` | 289 | Owns the single shared `ARSession`. Publishes `trackingQuality`, `meshAnchors`, `latestFrame`, `wallTextureReference`, and `wallMeshSnapshot` (a frozen copy of `meshAnchors` taken when the wall reference is captured — Step 4 renders this, never the live, still-growing `meshAnchors`). Also `captureWallTextureReference()`, `depthConfidenceRatio(for:)`. |
| `Core/Capture/VideoRecorderEngine.swift` | 253 | Renamed from `VideoRecorder`. Records ARKit camera frames to `.mp4` via `AVAssetWriter`; feeds each frame into its own `frameStore: ARFrameStore` keyed by ARKit timestamp. |
| `Core/Capture/ARFrameData.swift` | 143 | Renamed from `RecordedFrameStore.swift`. Defines `ARFrameData` (one frame's camera/depth data) and `ARFrameStore` (in-memory, capped-size store keyed by timestamp; deliberately never stores `capturedImage` — see the file's own doc comment for the OOM history). `nearestFrame(toPlaybackSeconds:clipStartTimestamp:)` is the lookup used by Step 4. |
| `Core/Capture/PixelBufferCopy.swift` | 44 | One helper: deep-copy a `CVPixelBuffer` (ARKit buffers are pool-reused and unsafe to hold onto raw). |
| `Core/Capture/VideoFrameExtractor.swift` | 35 | Pulls a single still frame out of a saved `.mp4` at an arbitrary timestamp — used by offline review's "Estimate 3D" path. |
| `Core/Capture/DeviceDiagnostics.swift` | 45 | Lightweight memory/thermal readouts for diagnosing crashes during the heaviest workload (recording). |
| `Core/ModelDB/EnumModels.swift` | 80 | `TrackingQuality`, `BodyJointName` (the 17-joint skeleton enum), `SkeletonBone` + the hard-coded `skeletonBones` list, `AnnotationTool`. Formerly part of `Core/Models.swift`. |
| `Core/ModelDB/AnnotationStrokeModel.swift` | 14 | `AnnotationStrokeModel` — one pen/line/angle stroke (tool + points). |
| `Core/ModelDB/VideoMarkerModel.swift` | 20 | `VideoMarkerModel` — one scrubber marker (has a drawing / has a 3D pose / is that pose approximate). |
| `Core/ModelDB/RouteGrade.swift` | 16 | `RouteGrade` enum, V0–V15. New concept — didn't exist pre-migration. |
| `Core/ModelDB/Climber.swift` | 28 | `@Model final class Climber` — a coach's climber, its own SwiftData table (not a string on a video attempt), keyed by `ownerID` like `RecordingSessionV2`. New concept. |
| `Core/ModelDB/RecordingSessionV2.swift` | 76 | `@Model final class RecordingSessionV2` — the wall-scan-level session: `ownerID`, `title`, `wallScanFolderName`, and `videoAttemptsData: Data` (JSON-encoded `[VideoAttemptV2]`, exposed via the `videoAttempts` computed property). One wall scan per session, but now potentially MANY video attempts. Also defines `VideoAnnotationEntry` (one timestamped drawing) at the bottom of the file. |
| `Core/ModelDB/VideoAttemptV2.swift` | 100 | `VideoAttemptV2` — one recorded clip within a session: file name/duration/orientation, `clipStartTimestamp`, `routeGrade`, `climberID`, plus its own `videoAnnotations: [VideoAnnotationEntry]` and `video3DLidarSkeletons: [Video3DLidarSkeleton]`. Everything that used to live directly on the old single-video `RecordingSession` and is genuinely per-clip now lives here. Manual `Codable` conformance. |
| `Core/ModelDB/Video3DLidarModel.swift` | 70 | `Video3DLidar` (a fully-loaded/generated reconstruction result, used at the View layer), `Video3DLidarInput` (what a generate call needs), `Video3DLidarSkeleton` (the persisted, `Codable` form saved onto a `VideoAttemptV2`). Renamed/restructured from the old `ReconstructionEntry` concept. |
| `Core/ModelDB/CodableSIMD.swift` | 84 | Retroactive `Codable` conformance for `SIMD3<Float>`, `SIMD4`, `simd_float3x3`, `simd_float4x4` — needed once, centrally, so every domain struct containing one can just add `: Codable`. |
| `Core/ModelDB/SessionFileStore.swift` | 73 | IMPLEMENTATION DETAIL OF `SessionStoreV2` — do not call from outside `Core/Persistence`. Resolves filenames/folder names stored on `RecordingSessionV2` into actual file paths (Application Support directory). Lives under `ModelDB`, not `Persistence`, despite the doc comment's own "don't call this from outside Core/Persistence" wording — a naming mismatch left over from the migration, not a functional problem. |
| `Core/ModelDB/WallScanArchive.swift` | 327 | IMPLEMENTATION DETAIL OF `SessionStoreV2` — same convention as `SessionFileStore`. Saves/loads an `ARSessionManager.WallTextureReference` to/from disk. **Flagged as the highest-risk file in the codebase** (raw `CVPixelBuffer` packing/unpacking, unverified on device). |
| `Core/Persistence/SessionStoreV2.swift` | 163 | **The only front door to persistence.** Every screen creates/reads/updates/deletes through this — never through `SessionFileStore`/`WallScanArchive` directly. `@MainActor`. Functions: `createSession(...)`, `fetchAll()`, `delete(_:)`, `save()`, `addVideoAttempt(to:...)`, `videoURL(for:)`, `removeVideoAttempt(_:from:)`, `save(_:in:)` (writes back an edited `VideoAttemptV2`), `wallTextureReference(for:)`, `mostRecentVideoAttempt()` (prefills the New Recording form), `fetchAllClimbers()`, `createClimber(name:)`. |
| `Core/Persistence/ClimberStore.swift` | 11 | **Empty stub** — just a header comment, no actual code. Climber CRUD (`fetchAllClimbers`/`createClimber`) actually lives on `SessionStoreV2` above, not here. Left over from the migration; don't look here for climber logic. |
| `Core/PoseReconstruction/AppleVisionSkeleton.swift` | 835 | **The Vision detection core.** Renamed/merged from `BodyPose3DExtractor.swift`. Defines `AppleVisionSkeleton` (raw Vision output, was `BodyPoseSample`) and the `AppleVisionSkeletonExtractor` enum (was `BodyPose3DExtractor`). Key functions: `detect(inVideoFrame:deviceOrientation:)`, `calibrateVisionToLidar(...)` (the LiDAR-grounded, root-anchored path — was `groundSkeletonRootAnchored`), `worldPosition(...)` (Vision-only fallback), `projected2DImagePoints(...)` (2D skeleton preview overlays). Also defines `DepthGroundingContext`, `LumaSource`/`LockedLuma` (bilateral-weighted depth lookup using color-frame brightness). |
| `Core/PoseReconstruction/Video3DRealityKit.swift` | 691 | **The RealityKit geometry builder.** Renamed from `ReconstructionEntityBuilder.swift`. Turns wall mesh anchors + a skeleton into renderable `Entity` objects: `wallEntity(...)`, `pointCloudWallEntity(...)` (bump-detailed textured wall from raw depth), `skeletonEntity(...)`, `generate3DJointPositions(...)`, `worldJointPositions`, `cylinderBetween` (shared by bones + mannequin capsules). |
| `Core/PoseReconstruction/Video3DLidarGenerator.swift` | 116 | Renamed from `LiveReconstructionGenerator.swift`. Runs the full **live** pipeline for one paused video moment: real recorded LiDAR depth + camera pose (from `ARFrameStore`) + Vision detection, grounded world positions. Higher-accuracy path vs. `AppleVisionEstimator`. |
| `Core/PoseReconstruction/AppleVisionEstimator.swift` | 85 | Renamed from `ReconstructionEstimator.swift`. Builds a `Video3DLidarSkeleton` from a saved video frame **without** live LiDAR depth — the fallback `OfflinePlaybackLayer` uses when a moment has no saved reconstruction yet. |
| `Core/PoseReconstruction/SkeletonPoseEditor.swift` | 221 | Manual joint-drag math with anatomical constraints (cone/hinge angle clamps per joint, clinical ROM figures) — keeps a coach's manual joint correction anatomically plausible. Pure math, no RealityKit dependency. Unchanged by the migration. |
| `Core/PoseReconstruction/JointDragProjector.swift` | 30 | Pure "unproject a 2D screen touch into a 3D drag" math, used by `Skeleton3DSceneView`'s gesture coordinator. Unchanged by the migration. |
| `Core/PoseReconstruction/PersonPresenceDetector.swift` | 53 | Lightweight "is anyone in this shot" check (`VNDetectHumanRectanglesRequest`) — used to skip auto-saving a wall reference frame that has a person standing in it. Unchanged by the migration. |

### Features/ (SwiftUI)

| File | Lines | What it's for |
|---|---|---|
| `Features/Recording/Pages/RecordingClimberView.swift` | 110 | New. Shown once per `ContentView` instance, before recording starts: picks a `RouteGrade` and either an existing `Climber` or types a new one (creates it via `createClimber`). Prefilled from `SessionStoreV2.mostRecentVideoAttempt()`. |
| `Features/Recording/Pages/RecordingEngineV2.swift` | 139 | Renamed/rewritten from `RecordingEngine.swift`. Owns the depth-quality polling timer, the periodic person-gated wall-mesh auto-save (now explicitly gated: only runs **before** the first recording this session — see `hasRecordedAtLeastOnce`/`markRecordingStarted()` — so every later clip reconstructs against the exact same wall reference), and a relocalization-timeout watchdog (`resumeAfterPause()` / `relocalizationTimedOut`) that wasn't in the pre-migration version. |
| `Features/Recording/Pages/RecordingViewV2.swift` | 268 | Renamed from `RecordingView.swift`. Now the WHOLE recording screen for a session, not just "point at the wall": live AR mesh view, record button, HD/FPS/Audio placeholder buttons, a thumbnail row of every clip recorded so far (`RecordingThumbnail`), and "End Session". Tapping a thumbnail opens `PlaybackLayerV2` as an overlay. |
| `Features/Recording/Pages/RecordingComponent/RecordingThumbnail.swift` | 69 | New. Horizontal scroll row of every `VideoAttemptV2` recorded this session; loads a first-frame thumbnail per clip via `VideoFrameExtractor`, tap to select. |
| `Features/Recording/Pages/PlaybackLayerV2.swift` | 150 | New coordinator view. Sits on top of `RecordingViewV2` when a clip is selected; toggles between `PlaybackViewV2` (2D) and `Skeleton3DView` (3D). `generateOrLoad` calls `Generate3DEngine.loadOrGenerate` using the LIVE `ARSessionManager`/`ARFrameStore`. **Note:** `saveCurrentReconstruction()` here hardcodes `isApproximate: true` on every save regardless of whether the reconstruction was actually LiDAR-grounded — a real quirk in the current code, not a documentation error. |
| `Features/Recording/Pages/PlaybackEngine.swift` | 71 | Plain logic (no SwiftUI), **shared** by `PlaybackViewV2` and `OfflinePlaybackView`. Answers "what drawing belongs to this video moment" and "what are all the saved moments" (scrubber markers). Saving is NOT this engine's job. |
| `Features/Recording/Pages/PlaybackViewV2.swift` | 225 | Renamed from `PlaybackView.swift`. 2D scrub/annotate view for the clip just recorded in this session. Uses `PlaybackOverlay`/`PlaybackPanel`/`ClimbInfoCard`/`AnnotateToolbar` below. |
| `Features/Recording/Pages/PlaybackComponent/PlaybackPanel.swift` | 255 | Scrubber + timeline + playback-speed menu + frame-step/play-pause buttons + per-marker dots on the scrubber track (colored by has-drawing/has-3D-pose/is-approximate). |
| `Features/Recording/Pages/PlaybackComponent/PlaybackOverlay.swift` | 104 | Bottom overlay hosting `PlaybackPanel` plus the hand-tool and "3D" generate buttons on either side. |
| `Features/Recording/Pages/PlaybackComponent/AnnotateToolbar.swift` | 249 | Defines `AnnotateToolbar` (undo/eraser/pencil + expandable `AnnotationPanel`) and `AnnotationPanel` (per-tool color buttons: pen/line/angle/circle/arrow/text). Despite living under `Features/Recording`, this is used by BOTH `PlaybackViewV2`/`OfflinePlaybackView` (Library) AND `Skeleton3DView` (Reconstruction) — cross-feature reuse from a non-`Commons` location. |
| `Features/Recording/Pages/PlaybackComponent/ClimbInfoCard.swift` | 33 | Small info card (date/grade/student) shown in the top-left of the playback screens. Currently hardcoded placeholder text ("Aug 9, 2026", "Grade: V3 / Red", "Student: Aji") — not wired to the real `VideoAttempt`/`Climber`/`RouteGrade` data yet. |
| `Features/Library/Components/LibraryRow.swift` | 52 | Renamed from `SessionRow.swift`. One row in the flattened library list — now renders a `LibraryEngine.Item` (one `VideoAttemptV2` + its parent session + resolved `Climber`), not a whole session: climber name, date, route grade, duration. |
| `Features/Library/Pages/LibraryEngine.swift` | 41 | Renamed/rewritten from the old session-level engine. `@MainActor struct`. Defines `Item` (video attempt + session + climber). `loadAllVideoAttempts()` flattens every session's clips into one sorted list; `items(_:matching:climberID:)` filters by search text AND/OR climber; `delete(_:)`, `fetchAllClimbers()`. |
| `Features/Library/Pages/LibraryView.swift` | 201 | **App's actual root screen.** Flattened, filterable clip list + climber-filter picker + "New Recording" entry point into `ContentView`. THIS FILE IS UI ONLY — talks to `LibraryEngine`, never `SessionStoreV2` directly. |
| `Features/Library/Pages/OfflinePlaybackLayer.swift` | 204 | Replaces the old `SessionReviewEngine`/`SessionReviewView`/`SavedReconstructionReviewView` trio (consolidated into one coordinator view + `OfflinePlaybackView`). Opened from the Library for a saved clip with no live AR session behind it. Toggles `OfflinePlaybackView` (2D) / `Skeleton3DView` (3D); when a moment has no saved reconstruction, falls back to `AppleVisionEstimator`'s no-depth Vision estimate. `saveCurrentReconstruction()` here correctly threads through `currentIsApproximate` (contrast with `PlaybackLayerV2`'s hardcoded `true` — see that file's note). |
| `Features/Library/Pages/OfflinePlaybackView.swift` | 222 | 2D scrub/annotate view for a saved session reopened from the Library — near-identical UI to `PlaybackViewV2` (same `PlaybackOverlay`/`PlaybackPanel`/`AnnotateToolbar`/`ClimbInfoCard` components), differing mainly in that it has no live `ARSessionManager`/`ARFrameStore` to hand a generate call. |
| `Features/Reconstruction/Pages/Generate3DEngine.swift` | 102 | Renamed from `ReconstructionHostEngine.swift`. `@MainActor` enum. `loadOrGenerate(input:video3DLidarSkeletons:wallReference:)` — loads a nearby saved pose, or runs `Video3DLidarGenerator` fresh; `save(...)` writes a `Video3DLidarSkeleton` back onto the owning `VideoAttemptV2` via `SessionStoreV2`. |
| `Features/Reconstruction/Pages/Skeleton3DView.swift` | 291 | Renamed from `ReconstructionView.swift`. Step 4's UI: the non-AR RealityKit scene (via `Skeleton3DSceneView`), mode controls (camera/edit-pose/annotate), reset pose, approximate-placement/no-climber-detected banners, delete confirmation. THIS FILE IS UI ONLY. |
| `Features/Reconstruction/Components/Skeleton3DSceneView.swift` | 714 | Renamed from `ReconstructionSceneView.swift` — the actual RealityKit rendering + gesture surface (`UIViewRepresentable` + `Coordinator`) behind `Skeleton3DView`. Grown substantially since the old doc's "deliberately left untouched" note: now has per-axis (X/Y/Z) drag handles for fine adjustment and a floating whole-body handle (drag the entire skeleton as one unit), in addition to plain per-joint dragging. `commitTrigger: SceneCommitTrigger` is a small callback bridge letting `Skeleton3DView`'s Back/Done buttons force-commit an in-progress selection before navigating away. |
| `Features/Onboarding/InitialScreen.swift`, `Tutorial1.swift`, `Tutorial2.swift`, `Tutorial3.swift`, `TutorialOne.swift` | 47/42/40/52/37 | Onboarding screens. **Still not wired into the app** (`SendSocietyApp` launches straight into `LibraryView`). Same known bugs as before the migration: `Tutorial2`/`Tutorial3` both reference image `"Tutorial1"`; `Tutorial3`'s button has an empty action. |
| `Features/Commons/Components/PlaybackModel.swift` | 55 | Thin `AVPlayer` wrapper (`@Published` play/pause/current time), shared between `PlaybackViewV2` and `OfflinePlaybackView`. Renamed folder only (`Shared` → `Commons`); content unchanged. |
| `Features/Commons/Components/AnnotationComponent.swift` | 248 | Renamed from `AnnotationOverlay.swift`. Defines `AnnotationState` (shared `ObservableObject`) and `AnnotationComponent` (the actual drawing canvas — pen/line/angle/circle/arrow tools, `isInteractive` toggle for read-only display). Also still defines an `AnnotationToolbar` View — **this one is now dead code**: every real screen (`PlaybackViewV2`, `OfflinePlaybackView`, `Skeleton3DView`) uses `AnnotateToolbar` from `Features/Recording/Pages/PlaybackComponent/AnnotateToolbar.swift` instead. Don't confuse the two similarly-named toolbars. |
| `Features/Commons/Components/ARMeshSceneView.swift` | 42 | Thin `UIViewRepresentable` wrapper around a live-passthrough RealityKit `ARView`, attached to the shared `ARSessionManager` session — used by `RecordingViewV2`. Unchanged by the migration. |
| `Features/Commons/Components/MeshToggleButton.swift` | 29 | Small button toggling the live LiDAR mesh wireframe on/off, backed by `DeveloperSettings.showMesh`. Unchanged by the migration. |
| `Features/Commons/Components/SkeletonImageOverlayView.swift` | 127 | Draws Vision's raw 2D detected skeleton on top of a single still frame. Unchanged by the migration (though nothing in the current screens visibly calls it — the old "Preview Skeleton" toggle from `SessionReviewView` doesn't have an obvious equivalent in `OfflinePlaybackView`; worth double-checking on-device whether this is still reachable UI or now-orphaned like `AnnotationToolbar`). |

### Root

| File | Lines | What it's for |
|---|---|---|
| `SendSocietyApp.swift` | 26 | `@main` entry point. Registers the SwiftData model container for `[RecordingSessionV2.self, Climber.self]` (was just `RecordingSession.self`). Shows `LibraryView` as the root. |
| `ContentView.swift` | 121 | Much smaller than pre-migration — no more `AppStep`/step-machine switch. Gates on `routeGrade`/`selectedClimber`: shows `RecordingClimberView` until both are picked, then `RecordingViewV2` (which now owns the entire record→review→generate flow internally via `PlaybackLayerV2`). Owns the shared `ARSessionManager` + `VideoRecorderEngine` for the session's lifetime; `addVideoAttempt(videoTempURL:)` is called on every recording-stop to append a new `VideoAttemptV2` to the (lazily-created) `RecordingSessionV2`. |

## 5. Persistence flow, in one paragraph

Every screen talks to `SessionStoreV2` only (never `SessionFileStore`/`WallScanArchive` directly —
those are private implementation details by convention, living under `Core/ModelDB` despite the
convention being phrased in terms of `Core/Persistence` in their own doc comments). `SessionStoreV2`
reads/writes two SwiftData `@Model` types: `RecordingSessionV2` (one per wall scan — big binary
data like the archived wall scan lives on disk as separate files referenced by folder name) and
`Climber` (one per coach's climber, its own table). A session's clips live as `videoAttemptsData: Data`
on `RecordingSessionV2` — a JSON-encoded `[VideoAttemptV2]` array, exposed via the `videoAttempts`
computed property. Each `VideoAttemptV2` in turn carries its OWN `videoAnnotations`
(`[VideoAnnotationEntry]`) and `video3DLidarSkeletons` (`[Video3DLidarSkeleton]`) as plain array
fields on that same struct — i.e. nested JSON-in-JSON, not separate SwiftData relationship models,
still avoiding a dependency on SwiftData relationship macros that couldn't be verified without a
compiler. The video file itself is referenced by filename (resolved via `SessionFileStore`), not
stored as a blob.

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
`Core/ModelDB/EnumModels.swift`, `Core/ModelDB/RouteGrade.swift`, `Core/ModelDB/AnnotationStrokeModel.swift`,
`Core/ModelDB/VideoMarkerModel.swift`, `Core/DebugLog.swift`, `Core/DeveloperSettings.swift`,
`Core/LiDARSupport.swift`, `Core/UserIdentity.swift`, `Core/ModelDB/CodableSIMD.swift`.

**Block 2 — Persistence models**
`Core/ModelDB/Climber.swift`, `Core/ModelDB/VideoAttemptV2.swift` → `Core/ModelDB/RecordingSessionV2.swift` →
`Core/ModelDB/SessionFileStore.swift` → `Core/ModelDB/WallScanArchive.swift` →
`Core/Persistence/SessionStoreV2.swift` (depends on all of the above). Skip
`Core/Persistence/ClimberStore.swift` — it's an empty stub, not part of the real build.

**Block 3 — Capture (getting AR/video data)**
`Core/Capture/PixelBufferCopy.swift`, `Core/Capture/DeviceDiagnostics.swift` →
`Core/Capture/ARSessionManager.swift` → `Core/Capture/ARFrameData.swift` →
`Core/Capture/VideoRecorderEngine.swift` → `Core/Capture/VideoFrameExtractor.swift`.

**Block 4 — Minimal end-to-end skeleton (get something on screen)**
`SendSocietyApp.swift` → a trivial placeholder `ContentView.swift`/`LibraryView.swift` just to
confirm the SwiftData container (`[RecordingSessionV2.self, Climber.self]`) + navigation shell boots.

**Block 5 — Recording screen**
`Features/Recording/Pages/RecordingClimberView.swift` → `Features/Recording/Pages/RecordingEngineV2.swift` →
`Features/Commons/Components/ARMeshSceneView.swift` → `Features/Commons/Components/MeshToggleButton.swift` →
`Features/Recording/Pages/RecordingComponent/RecordingThumbnail.swift` →
`Features/Recording/Pages/RecordingViewV2.swift`.
Needs Block 3 (ARSessionManager, VideoRecorderEngine) + Block 2 (Climber/RouteGrade) + Block 1.

**Block 6 — Playback (in-session review)**
`Features/Commons/Components/PlaybackModel.swift` → `Features/Commons/Components/AnnotationComponent.swift` →
`Features/Recording/Pages/PlaybackEngine.swift` →
`Features/Recording/Pages/PlaybackComponent/ClimbInfoCard.swift`,
`Features/Recording/Pages/PlaybackComponent/PlaybackPanel.swift`,
`Features/Recording/Pages/PlaybackComponent/PlaybackOverlay.swift`,
`Features/Recording/Pages/PlaybackComponent/AnnotateToolbar.swift` →
`Features/Recording/Pages/PlaybackViewV2.swift` → `Features/Recording/Pages/PlaybackLayerV2.swift`.
Needs Block 2 (SessionStoreV2/RecordingSessionV2) + Block 1 (AnnotationStroke).

**Block 7 — Pose reconstruction algorithm (still no UI)**
`Core/PoseReconstruction/PersonPresenceDetector.swift` → `Core/PoseReconstruction/AppleVisionSkeleton.swift`
(the big one — build/test in isolated pieces if possible: `detect`, then `calibrateVisionToLidar`,
then the fallback `worldPosition`) → `Core/PoseReconstruction/JointDragProjector.swift` →
`Core/PoseReconstruction/SkeletonPoseEditor.swift` → `Core/PoseReconstruction/Video3DRealityKit.swift` →
`Core/PoseReconstruction/Video3DLidarGenerator.swift` → `Core/PoseReconstruction/AppleVisionEstimator.swift`.

**Block 8 — Reconstruction screen**
`Features/Reconstruction/Pages/Generate3DEngine.swift` →
`Features/Reconstruction/Components/Skeleton3DSceneView.swift` →
`Features/Reconstruction/Pages/Skeleton3DView.swift`.
Needs Block 7 in full.

**Block 9 — Wire the recording pipeline together**
`ContentView.swift` for real — owns `ARSessionManager`/`VideoRecorderEngine`, gates on
`RecordingClimberView`, hosts `RecordingViewV2`, appends a new `VideoAttemptV2` to the session on
every recording-stop.

**Block 10 — Library / offline review**
`Features/Library/Components/LibraryRow.swift` → `Features/Library/Pages/LibraryEngine.swift` →
`Features/Library/Pages/LibraryView.swift` (now the real app root — update `SendSocietyApp.swift`) →
`Features/Commons/Components/SkeletonImageOverlayView.swift` →
`Features/Library/Pages/OfflinePlaybackView.swift` → `Features/Library/Pages/OfflinePlaybackLayer.swift`.

**Block 11 — Onboarding (optional / currently unused)**
`Features/Onboarding/*.swift` — build last, wire into `SendSocietyApp` only if/when you actually
want an onboarding flow; the rest of the app doesn't depend on it.

---

*When asking "how do I build X," name the screen/file and I'll pull the exact section above plus
read the current file(s) fresh — this doc is a map, not a substitute for reading real code before
editing it.*

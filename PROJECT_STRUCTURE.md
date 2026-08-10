# Send Society — Project Structure Guide

This doc explains how the codebase is organized and how a climb flows through it, so a new
frontend or backend developer can find their way around without reading every file first.

## What the app does

Send Society is a LiDAR climbing-coach app for iPad/iPhone. A coach scans a climbing wall,
optionally calibrates a climber's body measurements, records a climb on video, and then generates
a static 3D reconstruction of the climber's pose against the scanned wall — useful for reviewing
grip and foot placement after the fact. Everything is saved locally so a session can be reopened
and re-analyzed later.

## The two top-level folders

```
SendSociety/
├── Core/          the app's actual algorithms — no SwiftUI, no navigation
└── Features/      the screens — SwiftUI only, calls into Core
```

**Core is "the core function."** It takes plain data in (camera frames, joint samples, transforms)
and hands plain data or RealityKit entities back out. Nothing in `Core/` imports SwiftUI or knows
about navigation. This is deliberate: a backend developer can change how pose detection or
persistence works without touching a single screen, and a frontend developer can redesign a screen
without needing to understand LiDAR grounding math.

**Features is the UI.** Each subfolder is one screen (or a small group of related screens), split
into `Pages/` (the actual screen, wired to navigation and state) and `Components/` (reusable
rendering pieces that screen uses). `Features/Shared/Components/` holds pieces used by more than
one screen.

There are no separate Xcode targets or Swift Packages here — everything compiles into one app
target. The Core/Features split and the module folders inside Core are a **convention**, not a
compiler-enforced boundary. Please respect the "go through the entry point" rule in each module
(explained below) even though nothing will stop you from reaching around it.

## The user's path through the app

```
LibraryView (home screen)
   │
   │ "New Recording"
   ▼
ContentView (owns the 4-step pipeline + the one shared ARSession)
   │
   ├─ Step 1  WallScanView            scan the wall with LiDAR
   ├─ Step 2  CalibrationView         capture climber's body measurements (skippable)
   ├─ Step 3  RecordingView/PlaybackView   record the climb, scrub back, annotate
   └─ Step 4  ReconstructionView      generate + view the 3D pose reconstruction
   │
   │ "Done"
   ▼
back to LibraryView
```

From `LibraryView`, tapping a saved session instead opens `SessionReviewView` — play back the
video, revisit a saved 3D reconstruction, or run "Estimate 3D View" on a moment that was never
reconstructed live (lower-accuracy, since the real LiDAR depth from the original recording no
longer exists in memory by then).

`ContentView` is the only place that owns the shared `ARSessionManager` and the pipeline's
in-progress state (`currentSession`, the recorded video URL, etc.) — Steps 1-4 are just views it
swaps between.

## Core/ — the algorithms

### Core/ (flat files)

General-purpose types with no other home: `Models.swift` (shared value types like
`AnnotationStroke`, `BodyJointName`), `DebugLog.swift` (logging categories), `LiDARSupport.swift`
(device capability check), `UserIdentity.swift` (guest identity).

### Core/Capture/ — recording

Everything about running the AR session and getting a video + per-frame LiDAR data onto disk.

| File | Purpose |
|---|---|
| `ARSessionManager.swift` | Owns the single shared `ARSession` used across Steps 1-3; wall mesh, tracking quality, depth confidence. |
| `VideoRecorder.swift` | Encodes the camera feed to an MP4 via `AVAssetWriter`. |
| `RecordedFrameStore.swift` | Stores each frame's camera transform + depth (NOT the color image — that's re-extracted from the saved video on demand, since holding every frame's image in memory is what caused an early OOM crash). |
| `VideoFrameExtractor.swift` | Pulls a single color frame out of the saved video file at a given timestamp. |
| `PixelBufferCopy.swift` | Low-level `CVPixelBuffer` copying helper. |
| `DeviceDiagnostics.swift` | Memory/thermal logging during recording. |

### Core/PoseReconstruction/ — the actual climbing analysis

Vision body/hand detection, LiDAR grounding, grip/foot classification, manual pose-edit
constraints, and turning all of that into renderable RealityKit geometry. The two main entry
points most callers need are `BodyPose3DExtractor` (detection) and `ReconstructionEntityBuilder`
(turning a detected pose into world-space positions / 3D geometry).

| File | Purpose |
|---|---|
| `BodyPose3DExtractor.swift` | Runs Vision's body/hand pose requests and grounds joints in real LiDAR depth where available. |
| `ReconstructionEntityBuilder.swift` | Builds the RealityKit wall + skeleton entities; computes world-space joint positions. |
| `LiveReconstructionGenerator.swift` | The full pipeline behind Step 4's live "Generate" button (detection + grounding + grip/foot classification + nearby-frame fallback). |
| `ReconstructionEstimator.swift` | The lower-fidelity pipeline behind Session Review's "Estimate 3D View" (no live LiDAR depth available at that point). |
| `CalibrationEngine.swift` | Averages several frames of captured joint positions into one `CalibrationResult`. |
| `CalibrationFrameProcessor.swift` | Per-frame detection + grounding logic for Step 2's 15Hz capture loop. |
| `CalibrationHeightCorrection.swift` | Decides whether/how a climber's entered height should adjust the measured calibration. |
| `GripClassifier.swift` | Heuristics that classify a hand/foot position into a named grip/placement type. |
| `PresetPoseLibrary.swift` | Preset hand/foot pose geometry attached when a grip/placement is classified confidently. |
| `SkeletonPoseEditor.swift` | Anatomical joint-range-of-motion constraints used when a coach manually drags a joint. |
| `JointDragProjector.swift` | Pure ray/plane math for turning a 2D screen drag into a 3D joint position. |

### Core/Persistence/ — saving and loading

`SessionStore.swift` is **the front door** — it's the only type other code should call to
create/save/load/delete a `RecordingSession`. `SessionFileStore.swift` (video file storage) and
`WallScanArchive.swift` (saved wall mesh/texture data) are implementation details `SessionStore`
uses internally; please don't call them directly from a screen. `RecordingSession.swift` is the
SwiftData `@Model` itself, and `CodableSIMD.swift` bridges `simd` types (used throughout pose math)
so they can be stored in SwiftData/JSON.

> **SwiftData migration note:** every stored property on `RecordingSession` needs a literal
> default value in its declaration, not just in an initializer. Adding a new required property
> without one has silently broken loading existing saved sessions before — see the doc comment on
> `recordingDeviceOrientationRawValue` for the full story.

## Features/ — the screens

| Folder | Screen | Notes |
|---|---|---|
| `WallScan/Pages/WallScanView.swift` | Step 1 | Live mesh view + scan-coverage heatmap. |
| `Calibration/Pages/CalibrationView.swift` | Step 2 | Drives the 15Hz capture loop via `CalibrationFrameProcessor`; skippable. |
| `Calibration/Components/TPoseSilhouette.swift` | — | The T-pose guide overlay shape. |
| `Recording/Pages/RecordingView.swift` | Step 3 (record) | Wraps the record button + live mesh view. |
| `Recording/Pages/PlaybackView.swift` | Step 3 (scrub) | Shown after recording stops — scrubber, 2D annotation, "Generate 3D View" button. |
| `Reconstruction/Pages/ReconstructionView.swift` | Step 4 | Orbit-camera 3D view, Edit Pose / Annotate modes, grip/foot readout. |
| `Reconstruction/Components/ReconstructionSceneView.swift` | — | The actual RealityKit `UIViewRepresentable` + gesture handling `ReconstructionView` renders into. |
| `Library/Pages/LibraryView.swift` | Home | Chronological list of saved sessions. |
| `Library/Pages/SessionReviewView.swift` | Session review | Reopen a saved session's video/annotations/reconstructions. |
| `Library/Pages/SavedReconstructionReviewView.swift` | Session review | Renders one saved reconstruction with no live AR session needed. |
| `Library/Components/SessionRow.swift` | — | One row in the Library list. |
| `Shared/Components/ARMeshSceneView.swift` | — | Live camera + mesh-wireframe view, used by WallScan, Calibration, and Recording. |
| `Shared/Components/AnnotationOverlay.swift` | — | 2D pen/line/angle markup surface, used by Recording and Reconstruction and Session Review. |
| `Shared/Components/PlaybackModel.swift` | — | `AVPlayer` wrapper backing the video scrubber, used by Recording and Session Review. |

`ContentView.swift` and `SendSocietyApp.swift` at the top level are the app entry point and the
Steps 1-4 pipeline coordinator — they're not really part of any one feature.

## Where to add new code

- **A new screen or a change to an existing screen's layout** → `Features/<Feature>/Pages/`.
- **A reusable piece of UI used by only one screen** → that screen's own `Components/` folder.
- **A reusable piece of UI used by more than one screen** → `Features/Shared/Components/`.
- **A change to how pose detection, grounding, or classification works** → `Core/PoseReconstruction/`.
- **A change to what gets saved or how** → go through `SessionStore` in `Core/Persistence/`; don't
  add new direct callers of `SessionFileStore`/`WallScanArchive`.
- **A change to recording/capture itself** → `Core/Capture/`.

## A note on testing

This project is developed and tested entirely on real LiDAR-equipped hardware — there's no
simulator support for LiDAR/ARKit, and changes are verified by rebuilding and running through the
4-step flow on-device rather than with unit tests or a local build. Keep that in mind when making a
change: prefer small, easy-to-verify edits, and check the doc comments near anything you're
touching — many of them record a real on-device bug that motivated the current approach.

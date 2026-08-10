# Send Society — LiDAR MVP (Phase 1)

Xcode project implementing the 4-step capture pipeline from the build brief: wall scan →
climber calibration → recording → static 3D reconstruction, all sharing one continuous
`ARSession`.

## Opening it

Open `SendSociety.xcodeproj` in Xcode 15+ on a Mac, select a LiDAR-equipped iPad as the run
destination (simulator can't provide LiDAR/camera data), and run.

## Important: this was built without a macOS/Xcode toolchain

This session ran in a Linux sandbox with no Xcode installed, so **nothing here has been
compiled or opened in Xcode**. The `.xcodeproj` was hand-generated (structurally validated —
balanced braces, every object reference resolves — but never built). Budget time for a first
build-and-fix pass. The code itself follows the suggested build order from the brief and is
organized so each step's risk is isolated:

- `SendSociety/Core/` — shared ARSession, LiDAR capability check, Vision 3D pose wrapper,
  calibration averaging, frame/depth store, structured logging (`DebugLog`, one category per
  success criterion in the brief).
- `SendSociety/Features/WallScan|Calibration|Recording|Reconstruction/` — one folder per step.

## Known risk areas — check these first on real hardware

1. **`BodyPose3DExtractor.worldPosition(...)`** (`Core/BodyPose3DExtractor.swift`) — composes
   `cameraTransform * cameraOriginMatrix * rootRelativeJoint` to place Vision's body-space
   joints into ARKit world space. This is the highest-risk math in the whole pipeline (it's what
   success criterion #4 — does the hand land on the hold — depends on). Apple documents
   `cameraOriginMatrix` only as "a transform from the skeleton hip to the camera"; the exact
   composition order is inferred from ARKit's own naming convention, not verified against a
   working sample. If the Step 4 skeleton is offset or rotated relative to the wall mesh, start
   here — you may need to invert `cameraOriginMatrix` or reorder the multiplication.
2. **No `ARDepthData` → `AVDepthData` bridge.** The brief asks for body pose detection "combined
   with the session's depth data." There's no stable public API to feed ARKit's LiDAR depth into
   `VNImageRequestHandler`'s `depthData:` parameter, so Vision runs on the color frame alone
   (it produces its own metric-scale estimate). ARKit's own depth map is still captured and
   stored per-frame for the world-space alignment work instead. Flagged in code comments in
   `BodyPose3DExtractor.detect(in:)`.
3. **`RecordedFrameStore` memory cap** (`Core/RecordedFrameStore.swift`) — every stored frame is
   a deep copy of the captured image + depth + confidence buffers (necessary because ARKit
   reuses its pixel buffer pool — a naive reference would silently go stale). That's real memory
   pressure, so storage is capped at 2700 frames (~90s) by default; past the cap, video keeps
   recording but Step 4 won't have depth data for that portion. Tune `maxStoredFrames` after
   watching real memory behavior.
4. **`ReconstructionEntityBuilder.meshResource(from:)`** — manually walks `ARMeshGeometry`'s raw
   vertex/index buffers to build a RealityKit `MeshResource`. This is a well-established pattern
   but wasn't compiled here — double check vertex stride/format assumptions if the wall mesh
   renders garbled.
5. **CGImagePropertyOrientation mapping** in `BodyPose3DExtractor.cameraOrientation()` assumes
   the standard landscape-right-native back camera convention. Verify pose detection isn't
   rotated 90°/180° on device.

## Explicitly out of scope (per the brief — don't add without checking first)

Draggable/posable skeleton, multi-frame animation, reach validation/IK, automatic hold
detection, 2D video annotation, cross-session persistence of wall scans or calibration, imported
video, UI polish beyond "clear enough to test with."

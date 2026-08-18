# Joint Gizmo Editor — Session Notes

*Living doc for the "replace free-drag joint editing with an axis gizmo" feature. Written by
Claude acting as mentor (not implementer) — Theo is writing the actual code. Read this back at
the start of any future session to pick up where we left off, instead of re-reading the whole
chat.*

Last updated: 2026-08-18.

## Goal (from Theo, 2026-08-18)

Replace the current "tap a joint → free-drag it anywhere" pose-editing interaction in
`Skeleton3DSceneView` with a proper 3-axis gizmo:

1. Remove the green highlight-on-tap behavior (impacted joints/bones turning green).
2. Remove free-form (non-axis-constrained) joint dragging.
3. On tapping a joint, show 3 colored arrow handles around it: X = red, Y = blue, Z = purple.
4. Dragging an arrow moves the joint only along that arrow's axis.
5. While dragging an arrow (e.g. X), the joint's own color temporarily swaps from yellow to
   that axis's color (red), then back to yellow when the drag ends.

## What the codebase already had before this session

Read in full: `PROJECT_STRUCTURE.md`, `README.md` (stale, pre-migration — ignored),
`Skeleton3DSceneView.swift`, `Video3DRealityKit.swift`, `SkeletonPoseEditor.swift`,
`JointDragProjector.swift`, `Skeleton3DView.swift`, `EnumModels.swift` (skimmed).

Surprising finding: the **math and hit-testing for axis-constrained dragging already exists** in
`Skeleton3DSceneView.Coordinator` — `HandleAxis` enum (private, x/y/z + `worldDirection` only, no
color), `axisHandleWithinRadius`, `beginAxisDrag`, `updateAxisDrag` (projects the drag ray onto
the axis line via `closestPointOnLine`, then calls `SkeletonPoseEditor.dragJoint`). What's
missing is purely the **visual side**: no arrows are ever rendered, so today a coach has no way
to discover or aim at those invisible axis handles. So requirement 4's underlying logic is
basically done; requirements 3 and 5 are the real new work, and 1/2 are deletions.

Also still active (to be removed): free-form dragging via `beginJointDrag`/`updateJointDrag` +
`JointDragProjector.project` (camera-facing-plane projection), and green highlight via
`highlightedJoints`/`highlightedBones` params on `Video3DRealityKit.skeletonEntity`, sourced from
`SkeletonPoseEditor.impactedJoints`/`impactedBones`.

## Plan / file map

| # | Change | File(s) | Status |
|---|---|---|---|
| 1 | Remove green highlight | `Video3DRealityKit.swift` (`skeletonEntity` — drop `highlightedJoints`/`highlightedBones` params + the two highlight materials + the `isHighlighted` branches in the joint/bone loops); `Skeleton3DSceneView.swift` (`Coordinator.rebuildSkeleton()` — drop the `highlightedJoint`/`highlighted` computation and the args passed into `skeletonEntity(...)`) | Explained to Theo, not yet coded |
| 2 | Remove free-form drag | `Skeleton3DSceneView.swift` (`Coordinator`: delete the `withinRadius(selected, at:)` branch in `handleJointTouch`'s `.began`/`.joint` case, delete `beginJointDrag`/`updateJointDrag`/`withinRadius(_:at:)`, delete `isDraggingSelectedJoint`/`dragPlaneAnchor` state + their `.changed`/`.ended` branches). `JointDragProjector.swift` becomes dead code once this lands — grep for other callers before deleting the file. | Explained to Theo, not yet coded |
| 3 | Visible X/Y/Z arrow gizmo (red/blue/purple) | Promote the private `HandleAxis` enum to a shared type (`GizmoAxis`, suggested home: top of `Video3DRealityKit.swift`) with `worldDirection` (unchanged) + new `color: UIColor` (x=.systemRed, y=.systemBlue, z=.systemPurple). Add a new `Video3DRealityKit.axisGizmoEntities(at:handleLength:activeAxis:)` built from the existing private `cylinderBetween` helper (shaft) + a small sphere at the tip (arrowhead) — same trick already used to cap the mannequin's cylinder joints. Call it from inside `skeletonEntity(...)` when a `selectedJoint` param is passed, keeping the codebase's existing "one function builds the whole rendered entity" rule (see that function's own doc comment) instead of a second entity-management path in the Coordinator. | Explained to Theo, not yet coded |
| 4 | Drag arrow → move joint on that axis | Mostly done already (`updateAxisDrag`). Only needs: (a) `draggedAxis`'s type swapped from the private `HandleAxis` to the new shared `GizmoAxis`, (b) confirm the gizmo's rendered arrow length matches `Coordinator.axisHandleLength` (0.15) exactly — pass that constant into the render call rather than hardcoding a second copy of `0.15`, so hit-test and visuals can never drift apart. | Mostly pre-existing; wiring explained |
| 5 | Joint recolors to axis color while dragging | `Video3DRealityKit.skeletonEntity` gains `selectedJoint: BodyJointName?` and `activeDragAxis: GizmoAxis?` params (replacing the removed highlight params). In the joint-sphere loop: if `joint == selectedJoint && activeDragAxis != nil`, use `activeDragAxis!.color`, else `.systemYellow`. Coordinator passes its own `draggedAxis` straight through in `rebuildSkeleton()`. | Explained to Theo, not yet coded |

## Side effects Theo should also handle

- `Skeleton3DView.swift`'s `modeInstructions` text (~line 235) still says "Drag near it to
  correct it" — stale once free-drag is gone; update the copy to describe the arrow-drag gizmo.
- Tapping the *already-selected* joint's own sphere (not an arrow) will now fall through to
  `finishEditingSelection()` instead of starting a free-drag — i.e. tap-to-select, tap-again (or
  tap elsewhere) to deselect. Worth confirming this feels right on-device.
- Whole-body-handle selection (`selectWholeBodyHandle`) reuses the same axis-drag hit-testing
  (`axisHandleWithinRadius(... around: cubeWorldPosition)`) but is out of scope for the 5 items
  above — it'll keep working but won't show visible arrows since gizmo rendering is wired only to
  `selectedJoint`. Flagged for later, not fixed now.
- After requirement 1+2 land, `SkeletonPoseEditor.impactedJoints`/`impactedBones` may become
  unused — grep before deleting.

## Working agreement

Claude is acting as senior-dev/mentor here: explains reasoning, points to exact
files/functions/line numbers, gives short illustrative snippets — Theo writes and applies the
actual edits. Claude is not supposed to just hand over a full diff.

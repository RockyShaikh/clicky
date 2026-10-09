# WS4 — Annotation renderer (shapes, mapping, snapping, click detection)

**Branch:** `ws/annotations` · **Runs:** Phase 1, parallel · **Read first:** CONTRACTS.md §5–§8, research/04, upstream `OverlayWindow.swift` (read only: bezier flight, multi-monitor mapping).

## Goal
Turn `respond` shapes (screenshot pixels) into crisp, correctly placed drawings on the right screen, with optional snapping to the real UI element and click detection for walkthrough steps.

## You own (new files only)
- `leanring-buddy/AnnotationShape.swift` — Codable models matching CONTRACTS §5 (+ `WalkthroughStep`)
- `leanring-buddy/AnnotationCoordinateMapper.swift` — image px → AppKit global points (CONTRACTS §8); also global → screen-local for drawing
- `leanring-buddy/AccessibilityElementSnapper.swift` — `AXUIElementCopyElementAtPosition` on the system-wide element; returns `AXFrame` if plausible (w < 600 pt, h < 200 pt), converting AX top-left global coords to AppKit
- `leanring-buddy/AnnotationLayerView.swift` + `AnnotationLayerState` — SwiftUI `Canvas`: circle, box, arrow (with head), label (pill text), path, highlight; draw-on animation (~250 ms; none with Reduce Motion); optional hand-drawn jitter seeded per shape; colors from `DesignSystem.swift` tokens
- `leanring-buddy/ClickTargetWatcher.swift` — global mouse-down monitor active only while a step expects a click; hit-test primary shape rect with 12 pt slack; emits `stepDone(index)`
- `test-fixtures/annotations/*.json` sample responses; unit tests for the mapper (include the upstream example: (1100,42) in 1280×831 on 1512×982 → (1299.4, 932.4)), multi-monitor with negative origins, and snapping conversion

Don't edit shared files; the lead mounts `AnnotationLayerView` in the overlay and connects the blue-cursor flight to the `primary` shape.

## Behavior
- Shapes stay while speech plays; fade over 400 ms starting 2 s after speech ends; `clear()` immediately on Esc / new summon.
- At most one `primary` shape (if several, first wins). If none, cursor doesn't fly.
- Snapping: only shapes with `snap: true`; if AX lookup fails or is implausible, draw the raw shape. Never block the main thread > 16 ms (do AX lookups off-main, then publish).
- Labels never overflow the screen edge (flip side if needed).

## Acceptance
- Mapper tests pass (single screen, Retina, two screens incl. one left of primary / above).
- A debug command (lead will expose) can render each fixture JSON correctly on Ayaan's displays.
- Snapping produces tight boxes on: a Finder toolbar button, a Notes menu item, a Safari/Chrome address bar.

## Report back
Files, test results, screenshots of fixtures rendered (save under `test-fixtures/annotations/renders/`, no personal content).

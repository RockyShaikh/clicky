# Grounding and drawing: getting the shape on the right pixel

## Techniques

| Technique | How | Strength | Plan-compatible |
|---|---|---|---|
| Coordinates in the reply (upstream v1) | Model returns x,y in screenshot pixels | One call; good for big targets | ✅ |
| Computer-use tool as oracle (upstream unused) | Declare a `computer` tool, read the proposed click | Uses click training | API only |
| Zoom and refine | Crop ~400×300 around first guess at full res, ask again, add offset | Small icons, dense UIs, 4K | ✅ (+1 call) |
| **Accessibility snap** | `AXUIElementCopyElementAtPosition` at the mapped point → `AXFrame`; ignore huge frames | Pixel-exact boxes in native apps, free | ✅ |
| Set-of-Mark | Draw numbered boxes (AX tree or OmniParser) on the image; model picks a number | Model chooses, code locates | ✅ |
| Dedicated grounding model | Claude says *what*; local UI-TARS/Holo/Qwen-VL says *where* | Offline, free per call | ✅ |

Context: ScreenSpot-Pro (pro apps, high-res) — official leaderboard has UI-TARS-1.5 ≈ 62%; recent frontier models self-report ≈ 80–90%.

## Accuracy recipe (in payoff order)

1. **Resize yourself** below the model limit (1280 long edge) and state the exact pixel size. Then one scale factor maps back.
2. Ask Claude for **absolute pixel coordinates**, never 0–1000.
3. **Points vs pixels.** Retina images are 2× the display's points; overlays draw in points; add display origin for multi-monitor; AppKit is bottom-left, ScreenCaptureKit images are top-left.
4. **Snap** to the AX element under the point when `snap: true` (frame width < 600 pt and height < 200 pt, else keep the raw shape).
5. **Zoom** for small targets (`look` could later accept a crop rect).
6. **One target per step** for walkthroughs; wait for the click (`ClickTargetWatcher`: global `NSEvent` mouse-down monitor, hit-test the primary shape's mapped rect with ~12 pt slack), then re-capture and continue.
7. **Per-app notes** ("skills"): small Markdown files in `~/ClickyWorkspace/app-notes/<bundle_id>.md` the session reads for the frontmost app.
8. **Exclude our own windows** from capture (upstream already does via `SCContentFilter`).

## Drawing
- Shapes are primitives (CONTRACTS §5). Render in a SwiftUI `Canvas` per screen.
- Optional hand-drawn look: seeded jitter on paths (stable per shape so it doesn't shimmer).
- Draw-on animation (~250 ms) unless Reduce Motion; keep shapes while speaking; fade 2 s after speech ends; Esc clears.
- The blue cursor flies to the `emphasis: primary` shape (reuse upstream bezier flight).

## Sources
- https://platform.claude.com/docs/en/build-with-claude/vision-coordinates
- https://www.anthropic.com/news/developing-computer-use
- https://arxiv.org/abs/2310.11441 (Set-of-Mark) · https://github.com/microsoft/OmniParser · https://arxiv.org/abs/2501.12326 (UI-TARS)
- https://github.com/likaixin2000/ScreenSpot-Pro-GUI-Grounding · https://benchmarklist.com/benchmarks/screenspot_pro/

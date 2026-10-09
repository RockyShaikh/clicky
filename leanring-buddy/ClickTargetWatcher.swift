//
//  ClickTargetWatcher.swift
//  leanring-buddy
//
//  Watches for a left mouse-down inside a walkthrough step's primary shape.
//  The global monitor is installed only while a step expects a click, and it
//  is listen-only (it never consumes or blocks the user's click).
//

import AppKit

@MainActor
final class ClickTargetWatcher {
    private var globalMouseDownMonitor: Any?
    private var activeStepIndex: Int?

    var isWatching: Bool { globalMouseDownMonitor != nil }

    /// Starts watching for a click inside `targetRectInAppKitGlobalPoints` (plus 12 pt slack).
    /// `onStepDone` fires once with `stepIndex`, then the watcher stops itself.
    func startWatching(
        stepIndex: Int,
        targetRectInAppKitGlobalPoints: CGRect,
        onStepDone: @escaping @MainActor (Int) -> Void
    ) {
        stopWatching()
        activeStepIndex = stepIndex

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            // The monitor callback is delivered on the main thread; NSEvent.mouseLocation is AppKit global points.
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, let completedStepIndex = self.activeStepIndex else { return }
                let clickIsInsideTarget = AnnotationCoordinateMapper.isClick(
                    atAppKitGlobalPoint: clickLocation,
                    insideTargetRect: targetRectInAppKitGlobalPoints
                )
                guard clickIsInsideTarget else { return }
                self.stopWatching()
                onStepDone(completedStepIndex)
            }
        }
    }

    func stopWatching() {
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
        }
        globalMouseDownMonitor = nil
        activeStepIndex = nil
    }

    deinit {
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
        }
    }
}

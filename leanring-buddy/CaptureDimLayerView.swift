//
//  CaptureDimLayerView.swift
//  leanring-buddy
//
//  Standalone semi-gray dim + "Clicky is looking" pill for ONE screen. The lead mounts one
//  instance per screen inside the overlay's ZStack (CONTRACTS section 7). Ordering rule:
//  the screenshot must be fully captured BEFORE `presentDimAfterCaptureCompleted` is called,
//  so the dim can never end up in a capture (the capture also excludes our own windows).
//

import AppKit
import Combine
import CoreGraphics
import SwiftUI

enum CaptureDimLayerPhase: Equatable {
    case hidden
    case looking      // "Clicky is looking"
    case listening    // "Listening…"
    case thinking     // "Thinking…"

    var pillText: String {
        switch self {
        case .hidden: return ""
        case .looking: return "Clicky is looking"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        }
    }
}

@MainActor
final class CaptureDimLayerState: ObservableObject {
    static let dimOpacityPercentUserDefaultsKey = "clickyDimOpacityPercent"
    static let defaultDimOpacityPercent = 30
    static let allowedDimOpacityPercentRange = 15...45

    @Published private(set) var phase: CaptureDimLayerPhase = .hidden
    /// The screen being dimmed (NSScreen.frame, AppKit global points). Views for other screens stay clear.
    @Published private(set) var dimmedScreenFrameInAppKitGlobalPoints: CGRect?
    /// Cursor position at summon time (AppKit global points); the pill sits near it.
    @Published private(set) var cursorLocationInAppKitGlobalPoints: CGPoint = .zero
    /// Incremented each time the user cancels (Esc) so observers can react without Combine plumbing.
    @Published private(set) var cancelRequestCount = 0

    /// Called when Esc is pressed while summoned. The lead wires this to cancel the request.
    var onCancelRequested: (() -> Void)?

    private let userDefaults: UserDefaults
    private let escapeKeyMonitor = EscapeKeyCancelMonitor()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isVisible: Bool { phase != .hidden }

    var dimOpacity: Double {
        Self.clampedDimOpacity(
            percent: userDefaults.object(forKey: Self.dimOpacityPercentUserDefaultsKey) as? Int
                ?? Self.defaultDimOpacityPercent)
    }

    static func clampedDimOpacity(percent: Int) -> Double {
        let clampedPercent = min(max(percent, allowedDimOpacityPercentRange.lowerBound),
                                 allowedDimOpacityPercentRange.upperBound)
        return Double(clampedPercent) / 100
    }

    /// Call ONLY after the capture finished writing. Flips the dim visible and starts listening for Esc.
    func presentDimAfterCaptureCompleted(
        onScreenWithFrame screenFrame: CGRect,
        cursorLocation: CGPoint = NSEvent.mouseLocation
    ) {
        dimmedScreenFrameInAppKitGlobalPoints = screenFrame
        cursorLocationInAppKitGlobalPoints = cursorLocation
        phase = .looking
        SummonLatencySignposter.event("dim_visible")

        // Esc is only observed while summoned and the tap is torn down on dismiss: never a global hotkey.
        escapeKeyMonitor.start { [weak self] in self?.requestCancel() }
    }

    func setPhase(_ newPhase: CaptureDimLayerPhase) {
        guard phase != .hidden, newPhase != .hidden else { return }
        phase = newPhase
    }

    func dismiss() {
        escapeKeyMonitor.stop()
        phase = .hidden
        dimmedScreenFrameInAppKitGlobalPoints = nil
    }

    private func requestCancel() {
        cancelRequestCount += 1
        onCancelRequested?()
        dismiss()
    }
}

/// Listen-only Esc observer that exists only between start() and stop().
final class EscapeKeyCancelMonitor {
    private static let escapeKeyCode: Int64 = 53
    private var onEscapePressed: (() -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    deinit { stop() }

    func start(onEscapePressed: @escaping () -> Void) {
        stop()
        self.onEscapePressed = onEscapePressed

        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<EscapeKeyCancelMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
                if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if eventType == .keyDown,
                      event.getIntegerValueField(.keyboardEventKeycode) == EscapeKeyCancelMonitor.escapeKeyCode {
                monitor.onEscapePressed?()
            }
            return Unmanaged.passUnretained(event)
        }

        guard let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0) else {
            print("Escape cancel monitor: couldn't create CGEvent tap")
            return
        }
        eventTap = createdTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        onEscapePressed = nil
    }
}

struct CaptureDimLayerView: View {
    @ObservedObject var state: CaptureDimLayerState
    /// NSScreen.frame of the screen this view instance covers. The view stays clear unless it
    /// matches the screen being dimmed, so the lead can mount one per screen unconditionally.
    let screenFrame: CGRect

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDimmingThisScreen: Bool {
        state.isVisible && state.dimmedScreenFrameInAppKitGlobalPoints == screenFrame
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isDimmingThisScreen {
                Color.black.opacity(state.dimOpacity)
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                pill
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isDimmingThisScreen)
    }

    private var pill: some View {
        let pillPosition = pillCenterInViewPoints()
        return Text(state.phase.pillText)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1))
            .position(x: pillPosition.x, y: pillPosition.y)
    }

    /// Places the pill just below-right of the cursor, kept inside the screen. Converts AppKit
    /// global points (bottom-left origin) to view points (top-left origin).
    private func pillCenterInViewPoints() -> CGPoint {
        let localX = state.cursorLocationInAppKitGlobalPoints.x - screenFrame.origin.x
        let localY = screenFrame.height - (state.cursorLocationInAppKitGlobalPoints.y - screenFrame.origin.y)
        let halfPillWidth: CGFloat = 80
        let halfPillHeight: CGFloat = 16
        let centerX = min(max(localX + 24 + halfPillWidth, halfPillWidth + 8), screenFrame.width - halfPillWidth - 8)
        let centerY = min(max(localY + 28, halfPillHeight + 8), screenFrame.height - halfPillHeight - 8)
        return CGPoint(x: centerX, y: centerY)
    }
}

//
//  SummonKeyboardShortcutMonitor.swift
//  leanring-buddy
//
//  A quick single tap of Control+Option (pressed and released in under 250 ms with no
//  other key) summons Clicky. Uses its own listen-only CGEvent tap and leaves the
//  upstream hold-to-talk monitor untouched.
//

import AppKit
import CoreGraphics
import Foundation

/// Pure state machine for tap detection so it can be unit tested with synthetic events.
struct ControlOptionTapDetector {
    static let maximumTapDurationInSeconds: TimeInterval = 0.25

    private var pressStartTimestampInSeconds: TimeInterval?
    private var wasCandidateInvalidated = false

    /// Feed every flagsChanged event. Returns true when a valid tap just completed.
    mutating func handleModifierFlagsChanged(
        modifierFlags: NSEvent.ModifierFlags,
        timestampInSeconds: TimeInterval
    ) -> Bool {
        let relevantFlags = modifierFlags.intersection([.control, .option, .shift, .command, .function])
        let isExactlyControlOption = relevantFlags == [.control, .option]

        if let pressStartTimestampInSeconds {
            // A candidate press is in progress; any change away from exactly ctrl+option ends it.
            if isExactlyControlOption { return false }
            self.pressStartTimestampInSeconds = nil
            let wasInvalidated = wasCandidateInvalidated
            wasCandidateInvalidated = false
            // Adding shift/cmd/fn means a different shortcut; only releasing ctrl/option counts.
            let isReleaseOfControlOptionKeys = relevantFlags.isSubset(of: [.control, .option])
            let duration = timestampInSeconds - pressStartTimestampInSeconds
            return !wasInvalidated && isReleaseOfControlOptionKeys
                && duration >= 0 && duration < Self.maximumTapDurationInSeconds
        }

        if isExactlyControlOption {
            pressStartTimestampInSeconds = timestampInSeconds
            wasCandidateInvalidated = false
        }
        return false
    }

    /// Any regular key pressed while ctrl+option is down means it is a real shortcut, not a tap.
    mutating func handleKeyDown() {
        if pressStartTimestampInSeconds != nil { wasCandidateInvalidated = true }
    }
}

final class SummonKeyboardShortcutMonitor {
    /// Called on the main thread when a valid tap completes.
    var onSummonTapDetected: (() -> Void)?

    private var tapDetector = ControlOptionTapDetector()
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let eventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<SummonKeyboardShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handle(eventType: eventType, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Summon shortcut: couldn't create CGEvent tap (Input Monitoring / Accessibility permission?)")
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0) else {
            CFMachPortInvalidate(createdTap)
            return false
        }
        eventTap = createdTap
        eventTapRunLoopSource = runLoopSource
        // Tap callbacks run on the main run loop, so detector state is only touched on main.
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)
        return true
    }

    func stop() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        tapDetector = ControlOptionTapDetector()
    }

    private func handle(eventType: CGEventType, event: CGEvent) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        switch eventType {
        case .keyDown:
            tapDetector.handleKeyDown()
        case .flagsChanged:
            let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let timestampInSeconds = TimeInterval(event.timestamp) / 1_000_000_000
            if tapDetector.handleModifierFlagsChanged(
                modifierFlags: modifierFlags, timestampInSeconds: timestampInSeconds
            ) {
                SummonLatencySignposter.event("summon_trigger", detail: "keyboardShortcut")
                onSummonTapDetected?()
            }
        default:
            break
        }
    }
}

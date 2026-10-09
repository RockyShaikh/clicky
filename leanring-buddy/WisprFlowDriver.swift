//
//  WisprFlowDriver.swift
//  leanring-buddy
//
//  Starts and stops Wispr Flow dictation by synthesizing the trigger the user
//  bound inside Flow (a key chord or an extra mouse button). Flow itself then
//  types the cleaned-up text into whatever text field has focus.
//  Posting synthetic events requires the Accessibility permission the app already holds.
//

import AppKit
import CoreGraphics
import Foundation

enum WisprFlowTrigger: Equatable {
    /// A key plus modifiers, e.g. key code 105 (F13) with no modifiers.
    case keyChord(keyCode: CGKeyCode, modifierFlags: CGEventFlags)
    /// A non-primary mouse button. Button numbers follow CGEvent: 2 = middle, 3 = back, 4 = forward.
    case otherMouseButton(buttonNumber: Int)

    static let userDefaultsKindKey = "clicky.flow.triggerKind"               // "keyChord" | "mouseButton"
    static let userDefaultsKeyCodeKey = "clicky.flow.triggerKeyCode"         // Int
    static let userDefaultsModifierMaskKey = "clicky.flow.triggerModifiers"  // Int (CGEventFlags rawValue)
    static let userDefaultsMouseButtonKey = "clicky.flow.triggerMouseButton" // Int

    /// Default is F13 (key code 105), a key most keyboards never press, so it cannot collide with typing.
    /// Ayaan must bind the same key in Flow; the spike confirms the final choice.
    static func loadFromUserDefaults(_ userDefaults: UserDefaults = .standard) -> WisprFlowTrigger {
        if userDefaults.string(forKey: userDefaultsKindKey) == "mouseButton" {
            let buttonNumber = userDefaults.object(forKey: userDefaultsMouseButtonKey) as? Int ?? 3
            return .otherMouseButton(buttonNumber: buttonNumber)
        }
        let keyCode = userDefaults.object(forKey: userDefaultsKeyCodeKey) as? Int ?? 105
        let modifierMask = userDefaults.object(forKey: userDefaultsModifierMaskKey) as? Int ?? 0
        return .keyChord(keyCode: CGKeyCode(keyCode), modifierFlags: CGEventFlags(rawValue: UInt64(modifierMask)))
    }
}

@MainActor
final class WisprFlowDriver {
    static let wisprFlowBundleIdentifier = "com.electron.wispr-flow"

    /// Taps used to start dictation. 1 = Flow's trigger toggles recording; 2 = double-tap enters hands-free mode.
    static let startTapCountUserDefaultsKey = "clicky.flow.startTapCount"
    /// Taps used to stop. Usually 1.
    static let stopTapCountUserDefaultsKey = "clicky.flow.stopTapCount"

    private let userDefaults: UserDefaults
    private let delayBetweenTapsNanoseconds: UInt64 = 110_000_000

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isWisprFlowRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.wisprFlowBundleIdentifier).isEmpty
    }

    func startDictation() async {
        let tapCount = max(1, userDefaults.object(forKey: Self.startTapCountUserDefaultsKey) as? Int ?? 1)
        await sendTrigger(tapCount: tapCount)
    }

    func stopDictation() async {
        let tapCount = max(1, userDefaults.object(forKey: Self.stopTapCountUserDefaultsKey) as? Int ?? 1)
        await sendTrigger(tapCount: tapCount)
    }

    private func sendTrigger(tapCount: Int) async {
        let trigger = WisprFlowTrigger.loadFromUserDefaults(userDefaults)
        for tapIndex in 0..<tapCount {
            post(trigger)
            if tapIndex < tapCount - 1 {
                try? await Task.sleep(nanoseconds: delayBetweenTapsNanoseconds)
            }
        }
    }

    private func post(_ trigger: WisprFlowTrigger) {
        let eventSource = CGEventSource(stateID: .hidSystemState)

        switch trigger {
        case .keyChord(let keyCode, let modifierFlags):
            let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)
            let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
            keyDownEvent?.flags = modifierFlags
            keyUpEvent?.flags = modifierFlags
            keyDownEvent?.post(tap: .cghidEventTap)
            keyUpEvent?.post(tap: .cghidEventTap)

        case .otherMouseButton(let buttonNumber):
            // Posted at the current cursor position; the spike checks the app under the cursor ignores it.
            let cursorLocation = CGEvent(source: nil)?.location ?? .zero
            let mouseButton = CGMouseButton(rawValue: UInt32(buttonNumber)) ?? .center
            let mouseDownEvent = CGEvent(mouseEventSource: eventSource, mouseType: .otherMouseDown, mouseCursorPosition: cursorLocation, mouseButton: mouseButton)
            let mouseUpEvent = CGEvent(mouseEventSource: eventSource, mouseType: .otherMouseUp, mouseCursorPosition: cursorLocation, mouseButton: mouseButton)
            mouseDownEvent?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(buttonNumber))
            mouseUpEvent?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(buttonNumber))
            mouseDownEvent?.post(tap: .cghidEventTap)
            mouseUpEvent?.post(tap: .cghidEventTap)
        }
    }
}

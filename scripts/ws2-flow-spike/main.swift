// WS2 Wispr Flow spike harness. Run via scripts/ws2-flow-spike.sh from Terminal (Terminal needs the
// Accessibility permission). Not part of the app. Shows the key-capable panel, synthesizes Flow's
// trigger, and prints a timeline of text changes so insertion method and latency can be read off.
//
// Trigger overrides are plain UserDefaults argument-domain flags, e.g.
//   scripts/ws2-flow-spike.sh -clicky.flow.triggerKind mouseButton -clicky.flow.triggerMouseButton 3
//   scripts/ws2-flow-spike.sh -clicky.flow.triggerKeyCode 105 -clicky.flow.startTapCount 2
import AppKit

setbuf(stdout, nil)
let arguments = CommandLine.arguments
let shouldActivate = arguments.contains("--activating")
let secondsToRecord = Double(arguments.first(where: { $0.hasPrefix("--seconds=") })?.dropFirst(10) ?? "6") ?? 6

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let driver = WisprFlowDriver()
    let panel = VoiceInputPanel()
    let frontmostAtStart = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    let trigger = WisprFlowTrigger.loadFromUserDefaults()
    print("Flow running: \(driver.isWisprFlowRunning)  trigger: \(trigger)  frontmost at start: \(frontmostAtStart)  activating: \(shouldActivate)")

    let startTime = Date()
    func elapsed() -> String { String(format: "%6.3fs", Date().timeIntervalSince(startTime)) }
    panel.onTextChanged = { text in print("[\(elapsed())] text changed (\(text.count) chars): \(text)") }

    Task { @MainActor in
        panel.show(onScreenFrame: nil, hint: "WS2 spike: speak now", activateApplication: shouldActivate)
        try? await Task.sleep(nanoseconds: 500_000_000)
        print("[\(elapsed())] START trigger sent")
        await driver.startDictation()
        try? await Task.sleep(nanoseconds: UInt64(secondsToRecord * 1_000_000_000))
        print("[\(elapsed())] STOP trigger sent")
        await driver.stopDictation()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        print("[\(elapsed())] final text: \"\(panel.currentText)\"  frontmost now: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        exit(0)
    }
    application.run()
}

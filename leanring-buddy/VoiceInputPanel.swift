//
//  VoiceInputPanel.swift
//  leanring-buddy
//
//  A small borderless panel with one text field. Wispr Flow types its dictation
//  into the focused field, so the field must be able to take key focus even
//  though the panel is non-activating (the previously frontmost app stays frontmost).
//  Built in AppKit because SwiftUI cannot make a non-activating panel's field first responder reliably.
//

import AppKit

final class KeyCapableNonActivatingPanel: NSPanel {
    /// Allows the text field to become first responder without activating our app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws a horizontal bar whose fill follows the live microphone level.
private final class VoiceLevelMeterView: NSView {
    var level: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        let filledWidth = max(bounds.height, bounds.width * min(1, max(0, level)))
        let filledRect = NSRect(x: 0, y: 0, width: filledWidth, height: bounds.height)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: filledRect, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

@MainActor
final class VoiceInputPanel: NSObject, NSTextFieldDelegate {
    /// Called every time the field's text changes (typed by Wispr Flow or by the user).
    var onTextChanged: ((String) -> Void)?

    private let panel: KeyCapableNonActivatingPanel
    private let textField = NSTextField()
    private let hintLabel = NSTextField(labelWithString: "")
    private let levelMeterView = VoiceLevelMeterView()

    private let panelSize = NSSize(width: 420, height: 92)

    override init() {
        panel = KeyCapableNonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        configureSubviews()
    }

    var currentText: String { textField.stringValue }
    var isVisible: Bool { panel.isVisible }

    /// Shows the panel near the cursor on the captured screen and gives the text field key focus.
    /// If `activateApplication` is true the app is activated so Flow's paste keystroke reaches the field;
    /// the coordinator then restores the previous frontmost app.
    func show(onScreenFrame screenFrame: CGRect?, hint: String, activateApplication: Bool) {
        textField.stringValue = ""
        hintLabel.stringValue = hint
        levelMeterView.level = 0

        let targetScreenFrame = screenFrame
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.frame
            ?? NSScreen.main?.frame
            ?? .zero
        panel.setFrameOrigin(Self.panelOrigin(
            panelSize: panelSize,
            cursorLocation: NSEvent.mouseLocation,
            screenFrame: targetScreenFrame
        ))

        if activateApplication {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
    }

    func updateHint(_ hint: String) {
        hintLabel.stringValue = hint
    }

    func updateLevel(_ level: Float) {
        levelMeterView.level = CGFloat(level)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        onTextChanged?(textField.stringValue)
    }

    /// Places the panel just below-right of the cursor, kept fully inside the screen. Pure so it can be tested.
    static func panelOrigin(panelSize: NSSize, cursorLocation: CGPoint, screenFrame: CGRect) -> CGPoint {
        let edgeMargin: CGFloat = 12
        var originX = cursorLocation.x + 24
        var originY = cursorLocation.y - panelSize.height - 24

        originX = min(originX, screenFrame.maxX - panelSize.width - edgeMargin)
        originX = max(originX, screenFrame.minX + edgeMargin)
        originY = min(originY, screenFrame.maxY - panelSize.height - edgeMargin)
        originY = max(originY, screenFrame.minY + edgeMargin)
        return CGPoint(x: originX, y: originY)
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Keep the panel out of screenshots taken by other tools is not possible; the capture excludes our windows.
    }

    private func configureSubviews() {
        let backgroundView = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        backgroundView.material = .hudWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 14
        backgroundView.layer?.masksToBounds = true
        panel.contentView = backgroundView

        textField.frame = NSRect(x: 16, y: 44, width: panelSize.width - 32, height: 28)
        textField.placeholderString = "Listening…"
        textField.font = .systemFont(ofSize: 16)
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.textColor = .white
        textField.delegate = self
        backgroundView.addSubview(textField)

        levelMeterView.frame = NSRect(x: 16, y: 30, width: panelSize.width - 32, height: 5)
        backgroundView.addSubview(levelMeterView)

        hintLabel.frame = NSRect(x: 16, y: 8, width: panelSize.width - 32, height: 16)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        backgroundView.addSubview(hintLabel)
    }
}

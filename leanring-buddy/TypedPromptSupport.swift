//
//  TypedPromptSupport.swift
//  leanring-buddy
//
//  Pure logic for typed prompts, kept free of AppKit state so it can be unit tested.
//

import Foundation

/// What a key press in the summon panel's text field means.
enum SummonPanelKeyAction: Equatable {
    /// Return: submit the field text now.
    case submitTypedText
    /// A real keystroke from the user: pause the end-of-speech timeout.
    case userIsTyping
    /// Modifier-only presses, Esc (handled elsewhere) and command shortcuts. Wispr Flow delivers
    /// its dictation as a paste (Command+V), so command combos must NOT count as typing.
    case ignore
}

enum SummonPanelKeyClassifier {
    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76
    static let escapeKeyCode: UInt16 = 53

    /// `hasCommandControlOrOptionModifier` is true when Command, Control or Option is held.
    /// Shift+Return still submits (it has no second meaning in a one-line field).
    static func classify(keyCode: UInt16, hasCommandControlOrOptionModifier: Bool) -> SummonPanelKeyAction {
        if hasCommandControlOrOptionModifier { return .ignore }
        if keyCode == returnKeyCode || keyCode == keypadEnterKeyCode { return .submitTypedText }
        if keyCode == escapeKeyCode { return .ignore }
        return .userIsTyping
    }
}

enum TypedPromptText {
    /// Trimmed text, or nil when there is nothing to send.
    static func normalizedSubmission(from rawText: String) -> String? {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }
}

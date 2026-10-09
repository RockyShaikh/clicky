//
//  VoiceInputAndSpokenOutputProtocols.swift
//  leanring-buddy
//
//  Shared protocol declarations from CONTRACTS.md §6 for WS2 (voice in / voice out).
//  They live in their own file so the implementations (VoiceInputCoordinator,
//  LocalSpokenResponseOutput, ElevenLabsSpokenResponseOutput) and the hands-free
//  coordinator can all depend on them without depending on each other.
//
//  Both are @MainActor because every implementation drives UI (the input panel,
//  playback state that the overlay observes), and synchronous requirements such as
//  `cancelUtteranceCapture()` could not be satisfied by @MainActor classes otherwise.
//

import Foundation

@MainActor
protocol VoiceUtteranceProvider: AnyObject {
    /// Shows the input panel on the captured screen, runs Wispr Flow (or the fallback), and returns the final text.
    func captureUtterance(onScreen capturedScreen: CapturedScreenForRequest?) async throws -> String
    func cancelUtteranceCapture()
}

@MainActor
protocol SpokenResponseOutput: AnyObject {
    /// Returns only after playback has finished (or was stopped), not when it starts.
    func speak(_ text: String) async
    func stopSpeaking()
    var isSpeaking: Bool { get }
}

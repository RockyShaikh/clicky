//
//  LocalSpokenResponseOutput.swift
//  leanring-buddy
//
//  Speech output. `LocalSpokenResponseOutput` uses on-device AVSpeechSynthesizer (no keys).
//  `ElevenLabsSpokenResponseOutput` wraps the upstream ElevenLabs client behind the same protocol.
//  `speak` returns when speech has finished (or was stopped), not when it starts.
//

import AVFoundation
import Foundation

@MainActor
final class LocalSpokenResponseOutput: NSObject, ObservableObject, SpokenResponseOutput, AVSpeechSynthesizerDelegate {
    static let speechRateUserDefaultsKey = "clicky.voice.speechRate"          // Double, AVSpeechUtteranceMinimum...Maximum
    static let voiceIdentifierUserDefaultsKey = "clicky.voice.voiceIdentifier" // String, AVSpeechSynthesisVoice identifier

    @Published private(set) var isSpeaking = false

    private let speechSynthesizer = AVSpeechSynthesizer()
    private let userDefaults: UserDefaults
    /// Delegate callbacks for an old, cancelled utterance can arrive after a new one started; only the current one counts.
    private var currentUtterance: AVSpeechUtterance?
    private var finishedSpeakingContinuation: CheckedContinuation<Void, Never>?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        super.init()
        speechSynthesizer.delegate = self
    }

    func speak(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // A new utterance replaces whatever is still playing (barge-in).
        stopSpeaking()

        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.rate = (userDefaults.object(forKey: Self.speechRateUserDefaultsKey) as? Double).map { Float($0) } ?? AVSpeechUtteranceDefaultSpeechRate
        if let voiceIdentifier = userDefaults.string(forKey: Self.voiceIdentifierUserDefaultsKey),
           let configuredVoice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = configuredVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
        }

        currentUtterance = utterance
        isSpeaking = true
        await withCheckedContinuation { continuation in
            finishedSpeakingContinuation = continuation
            speechSynthesizer.speak(utterance)
        }
    }

    /// Immediate stop; also resolves any pending `speak` call.
    func stopSpeaking() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        markSpeechEnded()
    }

    private func markSpeechEnded() {
        currentUtterance = nil
        isSpeaking = false
        finishedSpeakingContinuation?.resume()
        finishedSpeakingContinuation = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.currentUtterance === utterance { self.markSpeechEnded() }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.currentUtterance === utterance { self.markSpeechEnded() }
        }
    }
}

@MainActor
final class ElevenLabsSpokenResponseOutput: ObservableObject, SpokenResponseOutput {
    @Published private(set) var isSpeaking = false

    private let elevenLabsTTSClient: ElevenLabsTTSClient

    init(elevenLabsTTSClient: ElevenLabsTTSClient) {
        self.elevenLabsTTSClient = elevenLabsTTSClient
    }

    func speak(_ text: String) async {
        isSpeaking = true
        defer { isSpeaking = false }

        do {
            try await elevenLabsTTSClient.speakText(text)
        } catch {
            print("⚠️ ElevenLabs speech failed: \(error.localizedDescription)")
            return
        }

        // speakText returns when playback starts, so wait for it to end.
        while elevenLabsTTSClient.isPlaying && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    func stopSpeaking() {
        elevenLabsTTSClient.stopPlayback()
        isSpeaking = false
    }
}

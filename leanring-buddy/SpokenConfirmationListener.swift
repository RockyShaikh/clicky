//
//  SpokenConfirmationListener.swift
//  leanring-buddy
//
//  Do mode confirmation loop (WS5): after a `confirm` event, speak the question, capture ONE
//  utterance, and classify it as yes / no. An unclear answer asks once more; a second unclear
//  answer counts as "no" so nothing irreversible runs on a mishear.
//

import Foundation

enum SpokenConfirmationAnswer: Equatable {
    case yes
    case no
    case unclear

    private static let negativeWords: Set<String> = [
        "no", "nope", "nah", "stop", "cancel", "don't", "dont", "wait", "never", "negative", "abort"
    ]
    private static let affirmativeWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm", "proceed", "submit", "continue", "affirmative"
    ]

    /// Simple word rules. Any negative word wins over an affirmative one ("yes wait" is a no).
    static func classify(_ answerText: String) -> SpokenConfirmationAnswer {
        let lowercasedAnswer = answerText.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let wordCharacters = CharacterSet.letters.union(CharacterSet(charactersIn: "'"))
        let answerWords = Set(
            lowercasedAnswer
                .components(separatedBy: wordCharacters.inverted)
                .filter { !$0.isEmpty }
        )
        if !answerWords.isDisjoint(with: negativeWords) { return .no }
        if !answerWords.isDisjoint(with: affirmativeWords) { return .yes }
        if lowercasedAnswer.contains("go ahead") || lowercasedAnswer.contains("do it") { return .yes }
        return .unclear
    }
}

struct SpokenConfirmationResult: Equatable {
    let answerIsYes: Bool
    let utteranceText: String
}

@MainActor
final class SpokenConfirmationListener {
    static let repeatQuestionText = "Sorry, I didn't get that. Is that a yes or a no?"

    private let voiceUtteranceProvider: VoiceUtteranceProvider
    /// Speaks text and returns when playback ended. Injected so the coordinator can pause the wake word around it.
    private let speakText: (String) async -> Void

    init(voiceUtteranceProvider: VoiceUtteranceProvider, speakText: @escaping (String) async -> Void) {
        self.voiceUtteranceProvider = voiceUtteranceProvider
        self.speakText = speakText
    }

    func askQuestionAndListenForAnswer(
        question: String,
        onScreen capturedScreen: CapturedScreenForRequest?
    ) async throws -> SpokenConfirmationResult {
        await speakText(question)
        try Task.checkCancellation()
        var answerText = try await voiceUtteranceProvider.captureUtterance(onScreen: capturedScreen)

        if SpokenConfirmationAnswer.classify(answerText) == .unclear {
            try Task.checkCancellation()
            await speakText(Self.repeatQuestionText)
            try Task.checkCancellation()
            answerText = try await voiceUtteranceProvider.captureUtterance(onScreen: capturedScreen)
        }

        return SpokenConfirmationResult(
            answerIsYes: SpokenConfirmationAnswer.classify(answerText) == .yes,
            utteranceText: answerText
        )
    }
}

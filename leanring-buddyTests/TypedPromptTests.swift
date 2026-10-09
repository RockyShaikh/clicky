//
//  TypedPromptTests.swift
//  leanring-buddyTests
//
//  Pure-logic tests for typed prompts (summon panel keys, text normalization).
//

import Testing
@testable import leanring_buddy

struct TypedPromptTests {

    @Test func returnKeySubmits() {
        #expect(SummonPanelKeyClassifier.classify(keyCode: 36, hasCommandControlOrOptionModifier: false) == .submitTypedText)
        #expect(SummonPanelKeyClassifier.classify(keyCode: 76, hasCommandControlOrOptionModifier: false) == .submitTypedText)
    }

    @Test func letterKeyCountsAsTyping() {
        #expect(SummonPanelKeyClassifier.classify(keyCode: 0, hasCommandControlOrOptionModifier: false) == .userIsTyping)
    }

    @Test func commandCombosAreIgnoredSoFlowPasteIsNotTyping() {
        // Command+V is how Wispr Flow delivers dictation.
        #expect(SummonPanelKeyClassifier.classify(keyCode: 9, hasCommandControlOrOptionModifier: true) == .ignore)
        #expect(SummonPanelKeyClassifier.classify(keyCode: 36, hasCommandControlOrOptionModifier: true) == .ignore)
    }

    @Test func escapeIsIgnoredByTheClassifier() {
        #expect(SummonPanelKeyClassifier.classify(keyCode: 53, hasCommandControlOrOptionModifier: false) == .ignore)
    }

    @Test func normalizedSubmissionTrimsAndRejectsEmpty() {
        #expect(TypedPromptText.normalizedSubmission(from: "  hello \n") == "hello")
        #expect(TypedPromptText.normalizedSubmission(from: "   \n") == nil)
        #expect(TypedPromptText.normalizedSubmission(from: "") == nil)
    }
}

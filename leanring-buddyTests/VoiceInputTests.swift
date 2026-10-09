//
//  VoiceInputTests.swift
//  leanring-buddyTests
//
//  Unit tests for the hardware-free parts of WS2 (voice input).
//

import AVFoundation
import CoreGraphics
import Testing
@testable import leanring_buddy

struct VoiceInputTests {

    private let loudLevel: Float = 0.1
    private let quietLevel: Float = 0.001

    private func makeTracker() -> EndOfSpeechTracker {
        EndOfSpeechTracker(settings: EndOfSpeechSettings())
    }

    @Test func endsAfterSilenceFollowingEnoughSpeech() {
        var tracker = makeTracker()
        var outcome: EndOfSpeechOutcome?

        for _ in 0..<10 { outcome = tracker.consume(rootMeanSquareLevel: loudLevel, bufferDurationSeconds: 0.1) }
        #expect(outcome == nil)

        // 0.8 s of silence is not enough, 0.9 s is.
        for _ in 0..<8 { outcome = tracker.consume(rootMeanSquareLevel: quietLevel, bufferDurationSeconds: 0.1) }
        #expect(outcome == nil)
        outcome = tracker.consume(rootMeanSquareLevel: quietLevel, bufferDurationSeconds: 0.1)
        #expect(outcome == .endOfSpeech)
    }

    @Test func briefNoiseDoesNotCountAsSpeech() {
        var tracker = makeTracker()
        // 0.1 s blip (< 0.3 s) then silence must not end the utterance as end-of-speech.
        _ = tracker.consume(rootMeanSquareLevel: loudLevel, bufferDurationSeconds: 0.1)
        var outcome: EndOfSpeechOutcome?
        for _ in 0..<20 { outcome = tracker.consume(rootMeanSquareLevel: quietLevel, bufferDurationSeconds: 0.1) }
        #expect(outcome != .endOfSpeech)
    }

    @Test func silenceAloneTimesOutAsNoSpeech() {
        var tracker = makeTracker()
        var outcome: EndOfSpeechOutcome?
        for _ in 0..<80 where outcome == nil {
            outcome = tracker.consume(rootMeanSquareLevel: quietLevel, bufferDurationSeconds: 0.1)
        }
        #expect(outcome == .noSpeechHeard)
    }

    @Test func continuousSpeechStopsAtThirtySeconds() {
        var tracker = makeTracker()
        var outcome: EndOfSpeechOutcome?
        for _ in 0..<400 where outcome == nil {
            outcome = tracker.consume(rootMeanSquareLevel: loudLevel, bufferDurationSeconds: 0.1)
        }
        #expect(outcome == .reachedMaximumUtteranceLength)
    }

    @Test func fieldTextMustBeNonEmptyAndUnchangedForHalfASecond() {
        var tracker = FieldTextStabilityTracker(requiredStableSeconds: 0.5)

        tracker.observe(text: "", atTime: 0)
        #expect(!tracker.isStable(atTime: 5))

        tracker.observe(text: "where do i", atTime: 6)
        #expect(!tracker.isStable(atTime: 6.3))

        tracker.observe(text: "where do i change the font", atTime: 6.4)
        #expect(!tracker.isStable(atTime: 6.8))
        #expect(tracker.isStable(atTime: 6.95))
        #expect(tracker.latestText == "where do i change the font")
    }

    @Test func ringBufferDropsOldestAudioBeyondItsLimit() throws {
        var ringBuffer = RollingAudioRingBuffer(maximumDurationSeconds: 1)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))

        for _ in 0..<5 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
            buffer.frameLength = 8000 // 0.5 s each
            ringBuffer.append(buffer)
        }

        #expect(ringBuffer.snapshotOfBuffers.count == 2)
        #expect(ringBuffer.bufferedDurationSeconds <= 1.0001)
    }

    @Test func panelStaysInsideScreenNearCursor() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let panelSize = CGSize(width: 420, height: 92)

        let nearCenter = VoiceInputPanel.panelOrigin(panelSize: panelSize, cursorLocation: CGPoint(x: 700, y: 500), screenFrame: screenFrame)
        #expect(nearCenter == CGPoint(x: 724, y: 384))

        let bottomRightCorner = VoiceInputPanel.panelOrigin(panelSize: panelSize, cursorLocation: CGPoint(x: 1500, y: 5), screenFrame: screenFrame)
        #expect(bottomRightCorner.x + panelSize.width <= screenFrame.maxX)
        #expect(bottomRightCorner.y >= screenFrame.minY)
    }
}

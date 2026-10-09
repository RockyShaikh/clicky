//
//  EndOfSpeechDetector.swift
//  leanring-buddy
//
//  Our own microphone tap used for two things while Wispr Flow records:
//  1. an energy-based voice activity detector that tells us when the user stopped talking, and
//  2. a rolling 30 second ring buffer of raw audio, so Apple Speech can transcribe
//     the utterance if Wispr Flow never delivers text.
//  macOS lets several apps read the microphone at once, so this does not disturb Flow.
//

import AVFoundation
import Foundation

/// Tunable voice-activity settings. Defaults follow the WS2 brief; each can be overridden in UserDefaults.
struct EndOfSpeechSettings: Equatable {
    /// Silence that must follow speech before we call it the end of the utterance.
    var requiredTrailingSilenceSeconds: TimeInterval = 0.9
    /// Speech that must be heard before silence is allowed to end the utterance (rejects clicks and coughs).
    var requiredSpeechSecondsBeforeSilenceCounts: TimeInterval = 0.3
    /// Hard cap on one utterance.
    var maximumUtteranceSeconds: TimeInterval = 30
    /// If nothing resembling speech is heard for this long, give up.
    var noSpeechTimeoutSeconds: TimeInterval = 8
    /// RMS amplitude (0...1) above which a buffer counts as speech. 0.015 is roughly -36 dBFS.
    var speechRootMeanSquareThreshold: Float = 0.015

    static let requiredTrailingSilenceUserDefaultsKey = "clicky.voice.endOfSpeechSilenceSeconds"
    static let requiredSpeechUserDefaultsKey = "clicky.voice.minimumSpeechSeconds"
    static let thresholdUserDefaultsKey = "clicky.voice.speechRMSThreshold"

    static func loadFromUserDefaults(_ userDefaults: UserDefaults = .standard) -> EndOfSpeechSettings {
        var settings = EndOfSpeechSettings()
        if userDefaults.object(forKey: requiredTrailingSilenceUserDefaultsKey) != nil {
            settings.requiredTrailingSilenceSeconds = userDefaults.double(forKey: requiredTrailingSilenceUserDefaultsKey)
        }
        if userDefaults.object(forKey: requiredSpeechUserDefaultsKey) != nil {
            settings.requiredSpeechSecondsBeforeSilenceCounts = userDefaults.double(forKey: requiredSpeechUserDefaultsKey)
        }
        if userDefaults.object(forKey: thresholdUserDefaultsKey) != nil {
            settings.speechRootMeanSquareThreshold = Float(userDefaults.double(forKey: thresholdUserDefaultsKey))
        }
        return settings
    }
}

enum EndOfSpeechOutcome: Equatable {
    case endOfSpeech
    case reachedMaximumUtteranceLength
    case noSpeechHeard
}

/// Pure, hardware-free voice activity state machine so it can be unit tested with synthetic levels.
struct EndOfSpeechTracker {
    let settings: EndOfSpeechSettings
    /// Buffer durations are summed as floating point, so 9 x 0.1 s is 0.8999999; compare with a small tolerance.
    private static let comparisonTolerance: TimeInterval = 0.000_001
    private(set) var totalElapsedSeconds: TimeInterval = 0
    private(set) var accumulatedSpeechSeconds: TimeInterval = 0
    private(set) var trailingSilenceSeconds: TimeInterval = 0

    init(settings: EndOfSpeechSettings) {
        self.settings = settings
    }

    /// Feeds one audio buffer's loudness. Returns an outcome when the utterance should end.
    mutating func consume(rootMeanSquareLevel: Float, bufferDurationSeconds: TimeInterval) -> EndOfSpeechOutcome? {
        totalElapsedSeconds += bufferDurationSeconds

        if rootMeanSquareLevel >= settings.speechRootMeanSquareThreshold {
            accumulatedSpeechSeconds += bufferDurationSeconds
            trailingSilenceSeconds = 0
        } else {
            trailingSilenceSeconds += bufferDurationSeconds
        }

        let hasHeardEnoughSpeech = accumulatedSpeechSeconds + Self.comparisonTolerance >= settings.requiredSpeechSecondsBeforeSilenceCounts

        if hasHeardEnoughSpeech && trailingSilenceSeconds + Self.comparisonTolerance >= settings.requiredTrailingSilenceSeconds {
            return .endOfSpeech
        }
        if hasHeardEnoughSpeech && totalElapsedSeconds + Self.comparisonTolerance >= settings.maximumUtteranceSeconds {
            return .reachedMaximumUtteranceLength
        }
        if !hasHeardEnoughSpeech && totalElapsedSeconds + Self.comparisonTolerance >= settings.noSpeechTimeoutSeconds {
            return .noSpeechHeard
        }
        return nil
    }
}

/// Keeps the most recent `maximumDurationSeconds` of audio buffers. Not thread-safe by itself.
struct RollingAudioRingBuffer {
    let maximumDurationSeconds: TimeInterval
    private var storedBuffers: [AVAudioPCMBuffer] = []
    private var storedDurationSeconds: TimeInterval = 0

    init(maximumDurationSeconds: TimeInterval = 30) {
        self.maximumDurationSeconds = maximumDurationSeconds
    }

    mutating func append(_ audioBuffer: AVAudioPCMBuffer) {
        storedBuffers.append(audioBuffer)
        storedDurationSeconds += Self.durationSeconds(of: audioBuffer)

        while storedDurationSeconds > maximumDurationSeconds, let oldestBuffer = storedBuffers.first {
            storedDurationSeconds -= Self.durationSeconds(of: oldestBuffer)
            storedBuffers.removeFirst()
        }
    }

    var bufferedDurationSeconds: TimeInterval { storedDurationSeconds }
    var snapshotOfBuffers: [AVAudioPCMBuffer] { storedBuffers }

    static func durationSeconds(of audioBuffer: AVAudioPCMBuffer) -> TimeInterval {
        let sampleRate = audioBuffer.format.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(audioBuffer.frameLength) / sampleRate
    }
}

enum EndOfSpeechDetectorError: LocalizedError {
    case microphoneNotAuthorized
    case audioEngineFailedToStart(String)

    var errorDescription: String? {
        switch self {
        case .microphoneNotAuthorized:
            return "microphone access is not granted."
        case .audioEngineFailedToStart(let reason):
            return "could not start the microphone: \(reason)"
        }
    }
}

/// Owns an `AVAudioEngine` input tap. Callbacks are delivered on the main actor.
@MainActor
final class EndOfSpeechDetector {
    /// Fires once per `start`, when the tracker decides the utterance is over.
    var onOutcome: ((EndOfSpeechOutcome) -> Void)?
    /// Loudness 0...1 for the panel's level meter.
    var onLevelUpdate: ((Float) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var isRunning = false

    // The tap callback runs on a realtime audio thread, so shared state is guarded by a lock.
    private nonisolated let sharedStateLock = NSLock()
    nonisolated(unsafe) private var tracker = EndOfSpeechTracker(settings: EndOfSpeechSettings())
    nonisolated(unsafe) private var ringBuffer = RollingAudioRingBuffer()
    nonisolated(unsafe) private var hasReportedOutcome = false

    func start(settings: EndOfSpeechSettings) throws {
        guard !isRunning else { return }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw EndOfSpeechDetectorError.microphoneNotAuthorized
        }

        sharedStateLock.lock()
        tracker = EndOfSpeechTracker(settings: settings)
        ringBuffer = RollingAudioRingBuffer(maximumDurationSeconds: settings.maximumUtteranceSeconds)
        hasReportedOutcome = false
        sharedStateLock.unlock()

        ClickyMicrophoneInputSelector.applyPreferredInputDevice(to: audioEngine)
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] audioBuffer, _ in
            self?.handleAudioBufferOnAudioThread(audioBuffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
        } catch {
            inputNode.removeTap(onBus: 0)
            throw EndOfSpeechDetectorError.audioEngineFailedToStart(error.localizedDescription)
        }
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
    }

    /// Audio captured since `start`, oldest first (capped at the ring buffer length).
    func bufferedAudioSinceStart() -> [AVAudioPCMBuffer] {
        sharedStateLock.lock()
        defer { sharedStateLock.unlock() }
        return ringBuffer.snapshotOfBuffers
    }

    private nonisolated func handleAudioBufferOnAudioThread(_ audioBuffer: AVAudioPCMBuffer) {
        // The engine reuses its buffer memory, so keep a private copy for the ring buffer.
        guard let bufferCopy = Self.makeCopy(of: audioBuffer) else { return }
        let rootMeanSquareLevel = Self.rootMeanSquareLevel(of: bufferCopy)
        let bufferDurationSeconds = RollingAudioRingBuffer.durationSeconds(of: bufferCopy)

        sharedStateLock.lock()
        ringBuffer.append(bufferCopy)
        var outcomeToReport: EndOfSpeechOutcome?
        if !hasReportedOutcome {
            outcomeToReport = tracker.consume(
                rootMeanSquareLevel: rootMeanSquareLevel,
                bufferDurationSeconds: bufferDurationSeconds
            )
            if outcomeToReport != nil { hasReportedOutcome = true }
        }
        sharedStateLock.unlock()

        let meterLevel = min(1, rootMeanSquareLevel * 8)
        Task { @MainActor [weak self] in
            self?.onLevelUpdate?(meterLevel)
            if let outcomeToReport {
                self?.onOutcome?(outcomeToReport)
            }
        }
    }

    nonisolated static func rootMeanSquareLevel(of audioBuffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = audioBuffer.floatChannelData, audioBuffer.frameLength > 0 else { return 0 }
        let samples = channelData[0]
        var sumOfSquares: Float = 0
        for sampleIndex in 0..<Int(audioBuffer.frameLength) {
            sumOfSquares += samples[sampleIndex] * samples[sampleIndex]
        }
        return (sumOfSquares / Float(audioBuffer.frameLength)).squareRoot()
    }

    private nonisolated static func makeCopy(of audioBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: audioBuffer.format, frameCapacity: audioBuffer.frameLength),
              let sourceChannels = audioBuffer.floatChannelData,
              let destinationChannels = copy.floatChannelData else { return nil }
        copy.frameLength = audioBuffer.frameLength
        for channelIndex in 0..<Int(audioBuffer.format.channelCount) {
            destinationChannels[channelIndex].update(from: sourceChannels[channelIndex], count: Int(audioBuffer.frameLength))
        }
        return copy
    }
}

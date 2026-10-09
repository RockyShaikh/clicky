//
//  VoiceInputCoordinator.swift
//  leanring-buddy
//
//  Implements `VoiceUtteranceProvider`: show the input panel, run Wispr Flow, wait for the
//  user to stop talking (our own VAD), stop Flow, wait for the text to settle, return it.
//  If Flow is not running or delivers no text in time, transcribe our own ring buffer
//  on-device with Apple Speech instead.
//

import AppKit
import AVFoundation
import Foundation

enum VoiceInputError: LocalizedError {
    case captureAlreadyInProgress
    case cancelled
    case noSpeechRecognized

    var errorDescription: String? {
        switch self {
        case .captureAlreadyInProgress: return "a voice capture is already running."
        case .cancelled: return "voice capture was cancelled."
        case .noSpeechRecognized: return "no speech was recognized."
        }
    }
}

enum VoiceTranscriptionPath: String {
    case wisprFlow
    case appleSpeechFallback
}

/// Decides when text in the panel field has "settled": non-empty and unchanged for `requiredStableSeconds`.
struct FieldTextStabilityTracker {
    let requiredStableSeconds: TimeInterval
    private(set) var latestText = ""
    private var lastChangeTime: TimeInterval?

    init(requiredStableSeconds: TimeInterval = 0.5) {
        self.requiredStableSeconds = requiredStableSeconds
    }

    mutating func observe(text: String, atTime currentTime: TimeInterval) {
        if text != latestText || lastChangeTime == nil {
            latestText = text
            lastChangeTime = currentTime
        }
    }

    func isStable(atTime currentTime: TimeInterval) -> Bool {
        guard let lastChangeTime else { return false }
        let hasText = !latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText && currentTime - lastChangeTime >= requiredStableSeconds
    }
}

@MainActor
final class VoiceInputCoordinator: VoiceUtteranceProvider {
    /// "nonactivating" (default) or "activating". Activating is the spike's fallback if Flow's paste
    /// does not reach a non-activating panel; the previous frontmost app is restored afterwards.
    static let panelActivationModeUserDefaultsKey = "clicky.voice.panelActivationMode"

    /// How long after stopping Flow we wait for text before falling back to Apple Speech.
    private let secondsToWaitForFlowTextAfterStop: TimeInterval = 2.5
    private let secondsFieldTextMustStayUnchanged: TimeInterval = 0.5
    private let fieldPollIntervalNanoseconds: UInt64 = 50_000_000

    private let wisprFlowDriver: WisprFlowDriver
    private let endOfSpeechDetector = EndOfSpeechDetector()
    private let voiceInputPanel = VoiceInputPanel()
    private let userDefaults: UserDefaults

    private var isCaptureInProgress = false
    private var wasCancelled = false
    private var earlyEndOfSpeechOutcome: EndOfSpeechOutcome?
    private var endOfSpeechContinuation: CheckedContinuation<EndOfSpeechOutcome?, Never>?

    /// Optional override; by default the latency line uses `ClickyLatencyLog.latestWakeRequestID` (CONTRACTS section 9).
    var requestIDForLatencyLog: String?

    /// The path used by the most recent capture, for logs and tests.
    private(set) var lastTranscriptionPath: VoiceTranscriptionPath?
    /// Seconds from end of speech to returning text, for the most recent capture.
    private(set) var lastSpeechEndToSubmitLatencySeconds: TimeInterval?

    init(wisprFlowDriver: WisprFlowDriver? = nil, userDefaults: UserDefaults = .standard) {
        self.wisprFlowDriver = wisprFlowDriver ?? WisprFlowDriver(userDefaults: userDefaults)
        self.userDefaults = userDefaults

        endOfSpeechDetector.onOutcome = { [weak self] outcome in
            self?.resumeEndOfSpeechWaiter(with: outcome)
        }
        endOfSpeechDetector.onLevelUpdate = { [weak self] level in
            self?.voiceInputPanel.updateLevel(level)
        }
    }

    func captureUtterance(onScreen capturedScreen: CapturedScreenForRequest?) async throws -> String {
        guard !isCaptureInProgress else { throw VoiceInputError.captureAlreadyInProgress }
        isCaptureInProgress = true
        wasCancelled = false
        earlyEndOfSpeechOutcome = nil
        lastTranscriptionPath = nil
        lastSpeechEndToSubmitLatencySeconds = nil

        let previouslyFrontmostApplication = NSWorkspace.shared.frontmostApplication
        let shouldUseFlow = wisprFlowDriver.isWisprFlowRunning
        var didStartFlow = false

        defer {
            endOfSpeechDetector.stop()
            voiceInputPanel.hide()
            restoreFrontmostApplication(previouslyFrontmostApplication)
            isCaptureInProgress = false
        }

        try endOfSpeechDetector.start(settings: EndOfSpeechSettings.loadFromUserDefaults(userDefaults))

        let shouldActivateApplication = userDefaults.string(forKey: Self.panelActivationModeUserDefaultsKey) == "activating"
        voiceInputPanel.show(
            onScreenFrame: capturedScreen?.displayFrameInAppKitGlobalPoints,
            hint: shouldUseFlow ? "Speak — Wispr Flow is listening" : "Speak — Wispr Flow not running, using on-device dictation",
            activateApplication: shouldActivateApplication
        )

        if shouldUseFlow {
            await wisprFlowDriver.startDictation()
            didStartFlow = true
        }

        let outcome = await waitForEndOfSpeech()
        let speechEndedTime = Date()

        if didStartFlow {
            await wisprFlowDriver.stopDictation()
        }
        if wasCancelled { throw VoiceInputError.cancelled }
        if outcome == .noSpeechHeard {
            throw VoiceInputError.noSpeechRecognized
        }

        var finalText: String?
        if didStartFlow {
            finalText = await waitForSettledFieldText()
            if wasCancelled { throw VoiceInputError.cancelled }
        }

        if let finalText {
            lastTranscriptionPath = .wisprFlow
            return finishCapture(text: finalText, path: .wisprFlow, speechEndedTime: speechEndedTime)
        }

        print("🎙️ Voice: Wispr Flow delivered no text, falling back to Apple Speech")
        let fallbackText = await transcribeWithAppleSpeech(audioBuffers: endOfSpeechDetector.bufferedAudioSinceStart())
        if wasCancelled { throw VoiceInputError.cancelled }
        guard let fallbackText else { throw VoiceInputError.noSpeechRecognized }

        return finishCapture(text: fallbackText, path: .appleSpeechFallback, speechEndedTime: speechEndedTime)
    }

    /// Stops Flow, hides the panel, discards any text. Safe to call when idle.
    func cancelUtteranceCapture() {
        guard isCaptureInProgress else { return }
        wasCancelled = true
        resumeEndOfSpeechWaiter(with: nil)
        // The capture itself sends Flow's stop trigger once its wait resumes, so we must not send a second one here.
    }

    // MARK: - Steps

    private func finishCapture(text: String, path: VoiceTranscriptionPath, speechEndedTime: Date) -> String {
        let latencySeconds = Date().timeIntervalSince(speechEndedTime)
        lastTranscriptionPath = path
        lastSpeechEndToSubmitLatencySeconds = latencySeconds
        print("🎙️ Voice: path=\(path.rawValue) speechEndToSubmit=\(String(format: "%.2f", latencySeconds))s chars=\(text.count)")
        if let requestID = requestIDForLatencyLog ?? ClickyLatencyLog.latestWakeRequestID {
            ClickyLatencyLog.record(
                requestID: requestID,
                event: "speech_end",
                extraFields: ["path": path == .wisprFlow ? "flow" : "apple"]
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitForEndOfSpeech() async -> EndOfSpeechOutcome? {
        // The outcome or a cancel may already have arrived while Flow was being started.
        if wasCancelled { return nil }
        if let earlyEndOfSpeechOutcome {
            self.earlyEndOfSpeechOutcome = nil
            return earlyEndOfSpeechOutcome
        }
        return await withCheckedContinuation { continuation in
            endOfSpeechContinuation = continuation
        }
    }

    private func resumeEndOfSpeechWaiter(with outcome: EndOfSpeechOutcome?) {
        if let endOfSpeechContinuation {
            endOfSpeechContinuation.resume(returning: outcome)
            self.endOfSpeechContinuation = nil
        } else {
            earlyEndOfSpeechOutcome = outcome
        }
    }

    /// Polls the panel field. Returns the text once it is non-empty and unchanged for 500 ms,
    /// or nil if nothing arrives within 2.5 s of Flow being stopped. If text arrived but kept
    /// changing until the deadline, returns what is there rather than discarding it.
    private func waitForSettledFieldText() async -> String? {
        var stabilityTracker = FieldTextStabilityTracker(requiredStableSeconds: secondsFieldTextMustStayUnchanged)
        let startTime = ProcessInfo.processInfo.systemUptime
        let deadlineTime = startTime + secondsToWaitForFlowTextAfterStop

        while ProcessInfo.processInfo.systemUptime < deadlineTime && !wasCancelled {
            let currentTime = ProcessInfo.processInfo.systemUptime
            stabilityTracker.observe(text: voiceInputPanel.currentText, atTime: currentTime)
            if stabilityTracker.isStable(atTime: currentTime) {
                return stabilityTracker.latestText
            }
            try? await Task.sleep(nanoseconds: fieldPollIntervalNanoseconds)
        }

        let leftoverText = voiceInputPanel.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        return leftoverText.isEmpty ? nil : leftoverText
    }

    private func transcribeWithAppleSpeech(audioBuffers: [AVAudioPCMBuffer]) async -> String? {
        guard !audioBuffers.isEmpty else { return nil }

        let provider = AppleSpeechTranscriptionProvider()
        let transcriptResultBox = TranscriptResultBox()

        let session: any BuddyStreamingTranscriptionSession
        do {
            session = try await provider.startStreamingSession(
                keyterms: [],
                onTranscriptUpdate: { latestPartialText in transcriptResultBox.latestPartialText = latestPartialText },
                onFinalTranscriptReady: { finalText in transcriptResultBox.deliver(finalText) },
                onError: { _ in transcriptResultBox.deliver(nil) }
            )
        } catch {
            print("⚠️ Voice: Apple Speech could not start: \(error.localizedDescription)")
            return nil
        }

        for audioBuffer in audioBuffers {
            session.appendAudioBuffer(audioBuffer)
        }
        session.requestFinalTranscript()

        // Give recognition a bounded time, then take whatever partial text exists.
        let deadlineTime = ProcessInfo.processInfo.systemUptime + 6
        while !transcriptResultBox.isDelivered && ProcessInfo.processInfo.systemUptime < deadlineTime && !wasCancelled {
            try? await Task.sleep(nanoseconds: fieldPollIntervalNanoseconds)
        }
        session.cancel()

        let transcriptText = (transcriptResultBox.finalText ?? transcriptResultBox.latestPartialText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return transcriptText.isEmpty ? nil : transcriptText
    }

    /// If the panel had to activate our app (or the OS shuffled focus), put the previous app back in front.
    private func restoreFrontmostApplication(_ previouslyFrontmostApplication: NSRunningApplication?) {
        guard let previouslyFrontmostApplication,
              previouslyFrontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let currentFrontmostApplication = NSWorkspace.shared.frontmostApplication
        if currentFrontmostApplication?.processIdentifier != previouslyFrontmostApplication.processIdentifier {
            previouslyFrontmostApplication.activate(options: [])
        }
    }
}

/// Apple Speech callbacks arrive on arbitrary queues; this small lock-guarded box carries the result back.
private final class TranscriptResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPartialText = ""
    private var storedFinalText: String?
    private var storedIsDelivered = false

    var latestPartialText: String {
        get { lock.withLock { storedPartialText } }
        set { lock.withLock { storedPartialText = newValue } }
    }
    var finalText: String? { lock.withLock { storedFinalText } }
    var isDelivered: Bool { lock.withLock { storedIsDelivered } }

    func deliver(_ text: String?) {
        lock.withLock {
            storedFinalText = text
            storedIsDelivered = true
        }
    }
}

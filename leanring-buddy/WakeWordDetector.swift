//
//  WakeWordDetector.swift
//  leanring-buddy
//
//  "Hey Clicky" detection implementing SummonTriggerProvider (CONTRACTS section 6).
//  Engine: Apple on-device SFSpeechRecognizer (no keys, no dependency, already used by the
//  repo). The recognizer is restarted every ~50 s because recognition tasks have time limits.
//  See docs/fork/research/06-wake-word-spike.md for why, and for the Porcupine fallback.
//

import AVFoundation
import CoreAudio
import Foundation
import Speech

enum SummonTriggerSource { case wakeWord, keyboardShortcut }

protocol SummonTriggerProvider: AnyObject {
    var summonTriggers: AsyncStream<SummonTriggerSource> { get }
    func pauseListeningWhileSpeaking(_ isSpeaking: Bool)
}

/// Pure phrase matching on recognizer text, separate for unit testing.
enum WakeWordPhraseMatcher {
    /// Spellings the recognizer commonly produces for "clicky".
    private static let clickyVariants: Set<String> = [
        "clicky", "clickey", "clicky's", "clickie", "cliqui", "klicky", "clikey",
    ]
    private static let greetingWords: Set<String> = ["hey", "hi", "hay", "a", "hei"]

    /// True when the text contains a greeting word immediately followed by a "clicky" variant.
    /// Requiring the greeting keeps plain talk about "click" or "clicky" from triggering.
    static func containsWakePhrase(in recognizedText: String) -> Bool {
        let words = recognizedText.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        guard words.count >= 2 else { return false }
        for index in 1..<words.count {
            if greetingWords.contains(words[index - 1]) && clickyVariants.contains(words[index]) { return true }
            // "click e" / "click ee" split into two words
            if index >= 2, greetingWords.contains(words[index - 2]), words[index - 1] == "click",
               ["e", "ee", "y", "key"].contains(words[index]) { return true }
        }
        return false
    }
}

final class WakeWordDetector: NSObject, SummonTriggerProvider {
    static let minimumSecondsBetweenTriggers: TimeInterval = 2.0
    private static let recognitionRestartIntervalInSeconds: TimeInterval = 50

    let summonTriggers: AsyncStream<SummonTriggerSource>
    private let summonTriggerContinuation: AsyncStream<SummonTriggerSource>.Continuation

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var isRunning = false
    private var isPausedWhileSpeaking = false
    private var lastTriggerDate = Date.distantPast
    /// Text already handled in the current recognition session, so one utterance triggers once.
    private var hasTriggeredInCurrentSession = false

    /// Timestamped to measure latency from phrase end to trigger in the spike harness.
    var onWakeWordDiagnosticLog: ((String) -> Void)?

    override init() {
        var capturedContinuation: AsyncStream<SummonTriggerSource>.Continuation!
        summonTriggers = AsyncStream { capturedContinuation = $0 }
        summonTriggerContinuation = capturedContinuation
        super.init()
    }

    deinit { stopListening() }

    func startListening() {
        guard !isRunning else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] authorizationStatus in
            DispatchQueue.main.async {
                guard let self, authorizationStatus == .authorized else {
                    print("Wake word: speech recognition not authorized")
                    return
                }
                self.isRunning = true
                self.beginRecognitionSession()
            }
        }
    }

    func stopListening() {
        isRunning = false
        restartTimer?.invalidate()
        restartTimer = nil
        tearDownRecognitionSession()
    }

    /// While our own TTS speaks, ignore detections (speakers would otherwise self-trigger).
    /// With headphones as the output route, no pausing is needed, and a spoken "Hey Clicky"
    /// barge-in stays possible.
    func pauseListeningWhileSpeaking(_ isSpeaking: Bool) {
        isPausedWhileSpeaking = isSpeaking && !Self.isDefaultOutputDeviceHeadphones()
    }

    // MARK: - Recognition session

    private func beginRecognitionSession() {
        guard isRunning, let speechRecognizer, speechRecognizer.isAvailable else {
            // Retry shortly if the recognizer is temporarily unavailable.
            if isRunning { scheduleRestart(after: 5) }
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        request.contextualStrings = ["Hey Clicky", "Clicky"]
        recognitionRequest = request
        hasTriggeredInCurrentSession = false

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("Wake word: audio engine failed to start: \(error)")
            scheduleRestart(after: 5)
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result { self.handle(recognizedText: result.bestTranscription.formattedString) }
                if error != nil || result?.isFinal == true { self.scheduleRestart(after: 0.2) }
            }
        }
        scheduleRestart(after: Self.recognitionRestartIntervalInSeconds)
    }

    private func handle(recognizedText: String) {
        guard !hasTriggeredInCurrentSession, !isPausedWhileSpeaking else { return }
        guard WakeWordPhraseMatcher.containsWakePhrase(in: recognizedText) else { return }
        guard Date().timeIntervalSince(lastTriggerDate) >= Self.minimumSecondsBetweenTriggers else { return }

        lastTriggerDate = Date()
        hasTriggeredInCurrentSession = true
        SummonLatencySignposter.event("summon_trigger", detail: "wakeWord")
        ClickyLatencyLog.recordWake(triggerDescription: "wakeWord")
        onWakeWordDiagnosticLog?("trigger: \(recognizedText)")
        summonTriggerContinuation.yield(.wakeWord)
        // Restart so the same utterance's later partials (and the user's request) don't re-trigger.
        scheduleRestart(after: 0.3)
    }

    private func scheduleRestart(after delayInSeconds: TimeInterval) {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: delayInSeconds, repeats: false) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.tearDownRecognitionSession()
            self.beginRecognitionSession()
        }
    }

    private func tearDownRecognitionSession() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Output route

    private static func isDefaultOutputDeviceHeadphones() -> Bool {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, 0, nil, &propertySize, &deviceID
        ) == noErr else { return false }

        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transportType) == noErr
        else { return false }

        // Bluetooth output is almost always headphones/earbuds. A wired 3.5 mm jack reports as
        // "built-in", so it is treated like speakers (conservative: pauses detection).
        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

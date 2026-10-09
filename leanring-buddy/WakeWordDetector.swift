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

/// How forgiving the wake phrase matcher is. Mapped from the 0...1 settings slider.
enum WakeWordSensitivityLevel: Equatable {
    /// Exactly "hey clicky".
    case strict
    /// Common recognizer spellings (the default).
    case normal
    /// Adds more greetings and sound-alike spellings; more false triggers.
    case loose

    init(sliderValue: Double) {
        if sliderValue < 1.0 / 3.0 {
            self = .strict
        } else if sliderValue < 2.0 / 3.0 {
            self = .normal
        } else {
            self = .loose
        }
    }
}

/// Pure phrase matching on recognizer text, separate for unit testing.
enum WakeWordPhraseMatcher {
    /// Spellings the recognizer commonly produces for "clicky".
    private static let normalClickyVariants: Set<String> = [
        "clicky", "clickey", "clicky's", "clickie", "cliqui", "klicky", "clikey",
    ]
    private static let looseOnlyClickyVariants: Set<String> = [
        "clicki", "cliquey", "clickee", "clikki", "glicky", "clickly", "kliki", "clique",
    ]
    private static let normalGreetingWords: Set<String> = ["hey", "hi", "hay", "a", "hei"]
    private static let looseOnlyGreetingWords: Set<String> = ["hello", "ok", "okay", "yo", "eh"]

    /// True when the text contains a greeting word immediately followed by a "clicky" variant.
    /// Requiring the greeting keeps plain talk about "click" or "clicky" from triggering.
    static func containsWakePhrase(
        in recognizedText: String,
        sensitivity: WakeWordSensitivityLevel = .normal
    ) -> Bool {
        let words = recognizedText.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        guard words.count >= 2 else { return false }

        let greetingWords: Set<String>
        let clickyVariants: Set<String>
        switch sensitivity {
        case .strict:
            greetingWords = ["hey"]
            clickyVariants = ["clicky"]
        case .normal:
            greetingWords = normalGreetingWords
            clickyVariants = normalClickyVariants
        case .loose:
            greetingWords = normalGreetingWords.union(looseOnlyGreetingWords)
            clickyVariants = normalClickyVariants.union(looseOnlyClickyVariants)
        }

        for index in 1..<words.count {
            if greetingWords.contains(words[index - 1]) && clickyVariants.contains(words[index]) { return true }
            // "click e" / "click ee" split into two words (not exact "hey clicky", so not in strict)
            if sensitivity != .strict, index >= 2, greetingWords.contains(words[index - 2]), words[index - 1] == "click",
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
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var isRunning = false
    private var lastTriggerDate = Date.distantPast
    /// Text already handled in the current recognition session, so one utterance triggers once.
    private var hasTriggeredInCurrentSession = false

    // The tap runs on a realtime audio thread and feeds whichever request is current, so the
    // request and the pause flag are lock-guarded. The engine itself runs for the whole listening
    // session: restarting it re-opens the mic, which flips Bluetooth headsets between A2DP and HFP.
    private let tapStateLock = NSLock()
    nonisolated(unsafe) private var currentRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    nonisolated(unsafe) private var isPausedWhileSpeaking = false

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
                guard !self.isRunning else { return }
                self.isRunning = true
                self.startAudioEngineIfNeeded()
                self.beginRecognitionSession()
            }
        }
    }

    func stopListening() {
        isRunning = false
        restartTimer?.invalidate()
        restartTimer = nil
        tearDownRecognitionSession()
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// While our own TTS speaks, buffers are dropped (the engine keeps running, so the mic is not
    /// reopened). Pausing is needed when the speakers could leak into the mic: the output is not
    /// headphones, or the capture device is itself Bluetooth (mic and speaker share the headset).
    /// With headphones out and a separate built-in mic, no pause is needed and a spoken
    /// "Hey Clicky" barge-in stays possible.
    func pauseListeningWhileSpeaking(_ isSpeaking: Bool) {
        let shouldPause = isSpeaking
            && (!Self.isDefaultOutputDeviceHeadphones() || ClickyMicrophoneInputSelector.isCaptureDeviceBluetooth())
        tapStateLock.lock()
        isPausedWhileSpeaking = shouldPause
        tapStateLock.unlock()
    }

    // MARK: - Audio engine (lives for the whole listening session)

    private func startAudioEngineIfNeeded() {
        guard !audioEngine.isRunning else { return }
        ClickyMicrophoneInputSelector.applyPreferredInputDevice(to: audioEngine)
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.tapStateLock.lock()
            let request = self.isPausedWhileSpeaking ? nil : self.currentRecognitionRequest
            self.tapStateLock.unlock()
            request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("Wake word: audio engine failed to start: \(error)")
            inputNode.removeTap(onBus: 0)
        }
    }

    // MARK: - Recognition session (rotated; the engine is not)

    private func beginRecognitionSession() {
        guard isRunning, let speechRecognizer, speechRecognizer.isAvailable else {
            // Retry shortly if the recognizer is temporarily unavailable.
            if isRunning { scheduleRestart(after: 5) }
            return
        }
        startAudioEngineIfNeeded()
        guard audioEngine.isRunning else {
            scheduleRestart(after: 5)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        request.contextualStrings = ["Hey Clicky", "Clicky"]
        hasTriggeredInCurrentSession = false
        tapStateLock.lock()
        currentRecognitionRequest = request
        tapStateLock.unlock()

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
        tapStateLock.lock()
        let isPaused = isPausedWhileSpeaking
        tapStateLock.unlock()
        guard !hasTriggeredInCurrentSession, !isPaused else { return }
        let sensitivitySliderValue = UserDefaults.standard.object(forKey: HandsFreeSettingsKeys.wakeWordSensitivity) as? Double ?? 0.5
        let sensitivity = WakeWordSensitivityLevel(sliderValue: sensitivitySliderValue)
        guard WakeWordPhraseMatcher.containsWakePhrase(in: recognizedText, sensitivity: sensitivity) else { return }
        guard Date().timeIntervalSince(lastTriggerDate) >= Self.minimumSecondsBetweenTriggers else { return }

        lastTriggerDate = Date()
        hasTriggeredInCurrentSession = true
        SummonLatencySignposter.event("summon_trigger", detail: "wakeWord")
        ClickyLatencyLog.recordWake(triggerDescription: "wakeWord")
        onWakeWordDiagnosticLog?("trigger: \(recognizedText)")
        summonTriggerContinuation.yield(.wakeWord)
        // Rotate the recognition so the same utterance's later partials (and the user's request) don't re-trigger.
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

    /// Ends only the recognition request and task. The audio engine and tap keep running.
    private func tearDownRecognitionSession() {
        tapStateLock.lock()
        let finishedRequest = currentRecognitionRequest
        currentRecognitionRequest = nil
        tapStateLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil
        finishedRequest?.endAudio()
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

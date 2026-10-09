//
//  HandsFreeSessionCoordinator.swift
//  leanring-buddy
//
//  Owns the hands-free state machine from docs/fork/ARCHITECTURE.md:
//
//    idle -> capturing -> listening -> thinking -> presenting -> idle
//                                        |  \-> awaitingConfirmation -> thinking
//                                        \-> awaitingClick -> thinking (after step_done)
//
//  A summon (wake word, or a quick Control+Option tap) captures the cursor screen, THEN dims it,
//  records one utterance, sends it to a BrainTransport (Claude Code channel, then headless), and
//  presents the response (annotations + spoken text). When no Claude Code transport is available
//  (or the user picked "direct" in settings) the utterance is handed to upstream's direct Claude
//  API path through `directAPIFallbackHandler`.
//
//  One request ID is used per summon: the one minted by `ClickyLatencyLog.recordWake`.
//

import Combine
import AppKit
import Foundation

enum HandsFreeSessionState: Equatable {
    case idle
    case capturing
    case listening
    case thinking
    case awaitingConfirmation
    case presenting
    case awaitingClick
}

/// Which brain the user prefers. The Claude Code transports always degrade towards direct.
enum BrainTransportPreference: String, CaseIterable {
    case channel
    case headless
    case direct

    static let userDefaultsKey = "clickyBrainTransportPreference"
    static let defaultPreference = BrainTransportPreference.channel

    static func load(from userDefaults: UserDefaults = .standard) -> BrainTransportPreference {
        userDefaults.string(forKey: userDefaultsKey).flatMap(BrainTransportPreference.init(rawValue:)) ?? defaultPreference
    }
}

/// UserDefaults keys for the hands-free settings that no workstream file already reads.
enum HandsFreeSettingsKeys {
    static let wakeWordEnabled = "clickyWakeWordEnabled"                 // Bool, default true
    static let wakeWordSensitivity = "clickyWakeWordSensitivity"         // Double 0...1, default 0.5
}

@MainActor
final class HandsFreeSessionCoordinator: ObservableObject {
    @Published private(set) var sessionState: HandsFreeSessionState = .idle
    /// Short visible message for failures the user should notice (cleared on the next summon).
    @Published private(set) var lastErrorMessage: String?

    /// Called with the transcript when no Claude Code transport can take the request, so the
    /// upstream direct Claude API path answers instead. The dim is already dismissed.
    var directAPIFallbackHandler: ((String) -> Void)?
    /// Called right before a summon captures, so the overlay windows that host the dim exist.
    var ensureOverlayIsVisibleHandler: (() -> Void)?
    /// Called whenever a session ends, so transient cursor mode can schedule its fade-out.
    var sessionFinishedHandler: (() -> Void)?
    /// Called when a session starts, so upstream push-to-talk / TTS state can be reset.
    var sessionStartedHandler: (() -> Void)?

    private let screenCaptureProvider: ScreenCaptureForRequestProvider
    private let voiceUtteranceProvider: VoiceUtteranceProvider
    private let spokenResponseOutput: SpokenResponseOutput
    private let wakeWordSummonProvider: SummonTriggerProvider?
    private let captureDimLayerState: CaptureDimLayerState
    private let annotationLayerStateForScreenFrame: (CGRect) -> AnnotationLayerState
    private let channelTransport: BrainTransport
    private let headlessTransport: BrainTransport
    private let brainTransportSelector: BrainTransportSelector
    private let userDefaults: UserDefaults
    private let clickTargetWatcher = ClickTargetWatcher()

    private var wakeWordConsumerTask: Task<Void, Never>?
    private var companionEventConsumerTask: Task<Void, Never>?
    private var summonTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?

    /// Bumped on every cancel / new summon; async work compares against it after each await.
    private var sessionGeneration = 0
    private var currentRequestID: String?
    private var mostRecentlyUsedRequestID: String?
    private var currentRequestWasSentToTransport = false
    private var activeTransport: BrainTransport?
    private var capturedScreensForCurrentRequest: [CapturedScreenForRequest] = []
    private var annotationLayerStateShowingShapes: AnnotationLayerState?
    private var currentWalkthroughStepIndex = 1

    init(
        screenCaptureProvider: ScreenCaptureForRequestProvider,
        voiceUtteranceProvider: VoiceUtteranceProvider,
        spokenResponseOutput: SpokenResponseOutput,
        wakeWordSummonProvider: SummonTriggerProvider?,
        captureDimLayerState: CaptureDimLayerState,
        annotationLayerStateForScreenFrame: @escaping (CGRect) -> AnnotationLayerState,
        channelTransport: BrainTransport = ClaudeCodeChannelTransport(),
        headlessTransport: BrainTransport = ClaudeCodeHeadlessTransport(),
        userDefaults: UserDefaults = .standard
    ) {
        self.screenCaptureProvider = screenCaptureProvider
        self.voiceUtteranceProvider = voiceUtteranceProvider
        self.spokenResponseOutput = spokenResponseOutput
        self.wakeWordSummonProvider = wakeWordSummonProvider
        self.captureDimLayerState = captureDimLayerState
        self.annotationLayerStateForScreenFrame = annotationLayerStateForScreenFrame
        self.channelTransport = channelTransport
        self.headlessTransport = headlessTransport
        self.brainTransportSelector = BrainTransportSelector(
            channelTransport: channelTransport,
            headlessTransport: headlessTransport
        )
        self.userDefaults = userDefaults
    }

    // MARK: - Lifecycle

    func start() {
        guard companionEventConsumerTask == nil else { return }

        // Esc (observed only while the dim is up) cancels the whole session.
        captureDimLayerState.onCancelRequested = { [weak self] in
            self?.cancelCurrentSession()
        }

        if let wakeWordSummonProvider {
            wakeWordConsumerTask = Task { [weak self] in
                for await summonTriggerSource in wakeWordSummonProvider.summonTriggers {
                    guard let self else { return }
                    guard self.userDefaults.object(forKey: HandsFreeSettingsKeys.wakeWordEnabled) as? Bool ?? true else { continue }
                    self.handleSummon(from: summonTriggerSource)
                }
            }
        }

        // AsyncStreams are single-consumer, so one long-lived loop dispatches every transport event.
        let mergedCompanionEvents = brainTransportSelector.mergedCompanionEvents
        companionEventConsumerTask = Task { [weak self] in
            for await companionEvent in mergedCompanionEvents {
                guard let self else { return }
                self.handleCompanionEvent(companionEvent)
            }
        }
    }

    func stop() {
        cancelCurrentSession()
        wakeWordConsumerTask?.cancel()
        wakeWordConsumerTask = nil
        companionEventConsumerTask?.cancel()
        companionEventConsumerTask = nil
        captureDimLayerState.onCancelRequested = nil
    }

    var isSessionInProgress: Bool { sessionState != .idle }

    // MARK: - Summon

    /// Entry point for both the wake word and the Control+Option tap. A summon during any
    /// non-idle state cancels the current request first (barge-in) and starts over.
    func handleSummon(from summonTriggerSource: SummonTriggerSource) {
        let requestID = makeRequestIDForNewSummon()
        cancelCurrentSession()

        sessionGeneration += 1
        let generationAtStart = sessionGeneration
        currentRequestID = requestID
        mostRecentlyUsedRequestID = requestID
        currentRequestWasSentToTransport = false
        currentWalkthroughStepIndex = 1
        lastErrorMessage = nil
        sessionStartedHandler?()

        summonTask = Task { [weak self] in
            await self?.runSummon(requestID: requestID, generation: generationAtStart)
        }
    }

    /// The wake word detector and the shortcut monitor both mint the ID when they fire. If it is
    /// missing or was already used by the previous summon, mint a fresh one so IDs are never shared.
    private func makeRequestIDForNewSummon() -> String {
        if let latestWakeRequestID = ClickyLatencyLog.latestWakeRequestID,
           latestWakeRequestID != mostRecentlyUsedRequestID {
            return latestWakeRequestID
        }
        return ClickyLatencyLog.recordWake(triggerDescription: "coordinator")
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == sessionGeneration && !Task.isCancelled
    }

    private func runSummon(requestID: String, generation: Int) async {
        // Read before our own UI takes focus.
        let frontmostApplication = NSWorkspace.shared.frontmostApplication

        do {
            sessionState = .capturing
            ensureOverlayIsVisibleHandler?()

            // Capture BEFORE dimming so the dim can never end up in the screenshot.
            let capturedScreens = try await screenCaptureProvider.captureScreensForNewRequest(requestID: requestID)
            guard isCurrent(generation) else { return }
            capturedScreensForCurrentRequest = capturedScreens
            let screenToDim = capturedScreens.first(where: { $0.isCursorScreen }) ?? capturedScreens.first

            if let screenToDim {
                captureDimLayerState.presentDimAfterCaptureCompleted(
                    onScreenWithFrame: screenToDim.displayFrameInAppKitGlobalPoints,
                    requestID: requestID
                )
            }

            sessionState = .listening
            captureDimLayerState.setPhase(.listening)
            let utteranceText = try await voiceUtteranceProvider.captureUtterance(onScreen: screenToDim)
            guard isCurrent(generation) else { return }

            let trimmedUtteranceText = utteranceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedUtteranceText.isEmpty else {
                finishSession()
                return
            }

            sessionState = .thinking
            captureDimLayerState.setPhase(.thinking)

            let companionRequest = CompanionRequest(
                requestID: requestID,
                utteranceText: trimmedUtteranceText,
                mode: .auto,
                capturedScreens: capturedScreens,
                frontmostApplicationName: frontmostApplication?.localizedName,
                frontmostApplicationBundleIdentifier: frontmostApplication?.bundleIdentifier,
                frontmostWindowTitle: nil,
                frontmostBrowserTabURL: nil,
                frontmostBrowserTabTitle: nil
            )

            guard let selectedTransport = await selectTransportForCurrentPreference() else {
                guard isCurrent(generation) else { return }
                print("Hands-free: no Claude Code transport available, using the direct Claude API path")
                finishSession(notifyFinishedHandler: false)
                directAPIFallbackHandler?(trimmedUtteranceText)
                return
            }
            guard isCurrent(generation) else { return }

            activeTransport = selectedTransport
            currentRequestWasSentToTransport = true
            try await selectedTransport.sendRequest(companionRequest)
        } catch is CancellationError {
            // A newer summon or Esc took over; the canceller already cleaned up.
        } catch VoiceInputError.cancelled {
            // Same: voice capture was cancelled on purpose.
        } catch VoiceInputError.noSpeechRecognized {
            guard isCurrent(generation) else { return }
            await reportFailure(spokenMessage: "I didn't catch that.", generation: generation)
        } catch {
            guard isCurrent(generation) else { return }
            print("Hands-free: request failed: \(error.localizedDescription)")
            await reportFailure(spokenMessage: "Sorry, that didn't work.", generation: generation, detail: error.localizedDescription)
        }
    }

    private func selectTransportForCurrentPreference() async -> BrainTransport? {
        switch BrainTransportPreference.load(from: userDefaults) {
        case .channel:
            return await brainTransportSelector.selectTransport()
        case .headless:
            return await headlessTransport.checkAvailability() ? headlessTransport : nil
        case .direct:
            return nil
        }
    }

    // MARK: - Transport events

    private func handleCompanionEvent(_ companionEvent: CompanionEvent) {
        switch companionEvent {
        case .status(let requestID, _):
            guard requestID == currentRequestID, sessionState == .thinking else { return }
            captureDimLayerState.setPhase(.thinking)
        case .respond(let companionResponse):
            guard companionResponse.requestID == currentRequestID else { return }
            present(companionResponse)
        case .confirm(let requestID, let question):
            guard requestID == currentRequestID else { return }
            askForConfirmation(question: question, requestID: requestID)
        case .error(let requestID, let message):
            guard requestID == nil || requestID == currentRequestID, sessionState != .idle else { return }
            let generationAtError = sessionGeneration
            presentationTask?.cancel()
            presentationTask = Task { [weak self] in
                await self?.reportFailure(spokenMessage: "Sorry, something went wrong.", generation: generationAtError, detail: message)
            }
        }
    }

    private func present(_ companionResponse: CompanionResponse) {
        let generationAtPresent = sessionGeneration
        presentationTask?.cancel()
        clickTargetWatcher.stopWatching()
        sessionState = .presenting

        // The dim lifts when shapes draw (ARCHITECTURE.md "Point/teach").
        captureDimLayerState.dismiss()

        let screenForResponse = capturedScreensForCurrentRequest.first(where: { $0.screenIndex == companionResponse.screenIndex })
            ?? capturedScreensForCurrentRequest.first
        var annotationLayerStateForResponse: AnnotationLayerState?
        if let screenForResponse, !companionResponse.annotationShapes.isEmpty {
            let annotationLayerState = annotationLayerStateForScreenFrame(screenForResponse.displayFrameInAppKitGlobalPoints)
            annotationLayerState.present(
                shapes: companionResponse.annotationShapes,
                imageWidthInPixels: screenForResponse.imageWidthInPixels,
                imageHeightInPixels: screenForResponse.imageHeightInPixels
            )
            annotationLayerStateShowingShapes = annotationLayerState
            annotationLayerStateForResponse = annotationLayerState
        }

        presentationTask = Task { [weak self] in
            guard let self else { return }
            await self.speakResponseText(companionResponse.spokenText, requestID: companionResponse.requestID)
            guard generationAtPresent == self.sessionGeneration, !Task.isCancelled else { return }

            let primaryShapeRect = annotationLayerStateForResponse?.primaryShapeRectInAppKitGlobalPoints
            if companionResponse.expectsClickOnPrimaryShape, let primaryShapeRect {
                // Shapes stay up until the user clicks the target; the next respond replaces them.
                self.waitForClick(inside: primaryShapeRect, requestID: companionResponse.requestID)
                return
            }

            annotationLayerStateForResponse?.speechDidEnd()
            if companionResponse.isFinalResponse {
                self.finishSession()
            } else {
                self.sessionState = .thinking
            }
        }
    }

    private func waitForClick(inside primaryShapeRect: CGRect, requestID: String) {
        sessionState = .awaitingClick
        let stepIndexToReport = currentWalkthroughStepIndex
        clickTargetWatcher.startWatching(
            stepIndex: stepIndexToReport,
            targetRectInAppKitGlobalPoints: primaryShapeRect
        ) { [weak self] completedStepIndex in
            guard let self, self.currentRequestID == requestID else { return }
            self.currentWalkthroughStepIndex += 1
            self.sessionState = .thinking
            Task { [weak self] in
                try? await self?.activeTransport?.sendFollowUp(.stepDone(requestID: requestID, stepIndex: completedStepIndex))
            }
        }
    }

    /// Speaks while the wake word is paused (so our own voice can't trigger it) and logs `tts_start`.
    private func speakResponseText(_ spokenText: String, requestID: String) async {
        let trimmedSpokenText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSpokenText.isEmpty else { return }
        wakeWordSummonProvider?.pauseListeningWhileSpeaking(true)
        ClickyLatencyLog.record(requestID: requestID, event: "tts_start")
        await spokenResponseOutput.speak(trimmedSpokenText)
        wakeWordSummonProvider?.pauseListeningWhileSpeaking(false)
    }

    // MARK: - Confirmation (do mode)

    private func askForConfirmation(question: String, requestID: String) {
        let generationAtQuestion = sessionGeneration
        presentationTask?.cancel()
        captureDimLayerState.dismiss()
        sessionState = .awaitingConfirmation

        presentationTask = Task { [weak self] in
            guard let self else { return }
            await self.speakResponseText(question, requestID: requestID)
            guard generationAtQuestion == self.sessionGeneration, !Task.isCancelled else { return }
            do {
                let answerText = try await self.voiceUtteranceProvider.captureUtterance(onScreen: self.capturedScreensForCurrentRequest.first)
                guard generationAtQuestion == self.sessionGeneration, !Task.isCancelled else { return }
                self.sessionState = .thinking
                try await self.activeTransport?.sendFollowUp(.confirmation(
                    requestID: requestID,
                    answerIsYes: Self.answerIsAffirmative(answerText),
                    utteranceText: answerText
                ))
            } catch VoiceInputError.cancelled {
                // Cancelled on purpose.
            } catch {
                guard generationAtQuestion == self.sessionGeneration else { return }
                await self.reportFailure(spokenMessage: "I didn't catch your answer, so I stopped.", generation: generationAtQuestion, detail: error.localizedDescription)
            }
        }
    }

    /// Conservative: anything that is not clearly "yes" counts as no, so nothing irreversible runs on a mishear.
    static func answerIsAffirmative(_ answerText: String) -> Bool {
        let answerWords = Set(answerText.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        let negativeWords: Set<String> = ["no", "nope", "stop", "cancel", "don't", "dont", "wait", "never"]
        let affirmativeWords: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm", "proceed", "submit", "continue"]
        if !answerWords.isDisjoint(with: negativeWords) { return false }
        if !answerWords.isDisjoint(with: affirmativeWords) { return true }
        let lowercasedAnswer = answerText.lowercased()
        return lowercasedAnswer.contains("go ahead") || lowercasedAnswer.contains("do it")
    }

    // MARK: - Failure and cancel

    /// Speaks a short message (fully visible text is kept in `lastErrorMessage`), lifts the dim, returns to idle.
    private func reportFailure(spokenMessage: String, generation: Int, detail: String? = nil) async {
        guard generation == sessionGeneration else { return }
        lastErrorMessage = detail.map { "\(spokenMessage) \($0)" } ?? spokenMessage
        captureDimLayerState.dismiss()
        if let currentRequestID {
            await speakResponseText(spokenMessage, requestID: currentRequestID)
        }
        guard generation == sessionGeneration else { return }
        finishSession()
    }

    /// Esc, or a new summon. Tears down everything a session may have started.
    func cancelCurrentSession() {
        sessionGeneration += 1
        summonTask?.cancel()
        summonTask = nil
        presentationTask?.cancel()
        presentationTask = nil

        voiceUtteranceProvider.cancelUtteranceCapture()
        spokenResponseOutput.stopSpeaking()
        wakeWordSummonProvider?.pauseListeningWhileSpeaking(false)
        clickTargetWatcher.stopWatching()
        annotationLayerStateShowingShapes?.clear()
        annotationLayerStateShowingShapes = nil
        captureDimLayerState.dismiss()

        if let requestID = currentRequestID, currentRequestWasSentToTransport, let transportToCancel = activeTransport {
            Task { await transportToCancel.cancelRequest(requestID: requestID) }
        }
        currentRequestID = nil
        currentRequestWasSentToTransport = false
        activeTransport = nil
        let wasInProgress = sessionState != .idle
        sessionState = .idle
        if wasInProgress { sessionFinishedHandler?() }
    }

    /// `notifyFinishedHandler` is false for the direct-API hand-off: that path schedules its own
    /// transient-cursor fade-out, and ours would hide the overlay while it is still answering.
    private func finishSession(notifyFinishedHandler: Bool = true) {
        captureDimLayerState.dismiss()
        wakeWordSummonProvider?.pauseListeningWhileSpeaking(false)
        currentRequestID = nil
        currentRequestWasSentToTransport = false
        activeTransport = nil
        sessionState = .idle
        if notifyFinishedHandler { sessionFinishedHandler?() }
    }
}

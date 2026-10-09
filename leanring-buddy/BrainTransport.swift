//
//  BrainTransport.swift
//  leanring-buddy
//
//  Transport-agnostic models and protocol for sending a spoken request (plus screenshots)
//  to "the brain" (a Claude Code session) and receiving events back. See docs/fork/CONTRACTS.md
//  sections 2 and 6. AnnotationShape and WalkthroughStep are owned by AnnotationShape.swift (WS4).
//

import Foundation

// MARK: - Request models

struct CapturedScreenForRequest: Codable, Equatable {
    let screenIndex: Int
    let imageFileURL: URL
    let imageWidthInPixels: Int
    let imageHeightInPixels: Int
    /// NSScreen.frame (AppKit bottom-left origin, global points).
    let displayFrameInAppKitGlobalPoints: CGRect
    let isCursorScreen: Bool
    let label: String
}

enum CompanionRequestMode: String, Codable {
    case auto
    case point
    case doTask = "do"
}

struct CompanionRequest: Codable {
    let requestID: String
    let utteranceText: String
    let mode: CompanionRequestMode
    let capturedScreens: [CapturedScreenForRequest]
    let frontmostApplicationName: String?
    let frontmostApplicationBundleIdentifier: String?
    let frontmostWindowTitle: String?
    let frontmostBrowserTabURL: String?
    let frontmostBrowserTabTitle: String?
}

enum CompanionFollowUp: Codable {
    case confirmation(requestID: String, answerIsYes: Bool, utteranceText: String)
    case stepDone(requestID: String, stepIndex: Int)
    case cancel(requestID: String)

    var requestID: String {
        switch self {
        case .confirmation(let requestID, _, _): return requestID
        case .stepDone(let requestID, _): return requestID
        case .cancel(let requestID): return requestID
        }
    }

    // Codable is only needed to satisfy the contract; the wire format is `bridgeWireJSONData()`.
    private enum CodingKeys: String, CodingKey {
        case kind, requestID, answerIsYes, utteranceText, stepIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requestID = try container.decode(String.self, forKey: .requestID)
        switch try container.decode(String.self, forKey: .kind) {
        case "confirmation":
            self = .confirmation(
                requestID: requestID,
                answerIsYes: try container.decode(Bool.self, forKey: .answerIsYes),
                utteranceText: try container.decode(String.self, forKey: .utteranceText)
            )
        case "step_done":
            self = .stepDone(requestID: requestID, stepIndex: try container.decode(Int.self, forKey: .stepIndex))
        default:
            self = .cancel(requestID: requestID)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        switch self {
        case .confirmation(_, let answerIsYes, let utteranceText):
            try container.encode("confirmation", forKey: .kind)
            try container.encode(answerIsYes, forKey: .answerIsYes)
            try container.encode(utteranceText, forKey: .utteranceText)
        case .stepDone(_, let stepIndex):
            try container.encode("step_done", forKey: .kind)
            try container.encode(stepIndex, forKey: .stepIndex)
        case .cancel:
            try container.encode("cancel", forKey: .kind)
        }
    }
}

// MARK: - Response / event models

struct CompanionResponse: Codable {
    let requestID: String
    let spokenText: String
    let screenIndex: Int
    let annotationShapes: [AnnotationShape]
    let walkthroughSteps: [WalkthroughStep]?
    let expectsClickOnPrimaryShape: Bool
    let isFinalResponse: Bool

    /// Wire format = the SSE `respond` payload (CONTRACTS section 2), which is also the
    /// headless `--json-schema` structured output (minus `request_id`, filled in by the transport).
    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case spokenText = "say"
        case screenIndex = "screen_index"
        case annotationShapes = "shapes"
        case walkthroughSteps = "steps"
        case expectsClickOnPrimaryShape = "expect_click"
        case isFinalResponse = "final"
    }

    init(
        requestID: String,
        spokenText: String,
        screenIndex: Int,
        annotationShapes: [AnnotationShape],
        walkthroughSteps: [WalkthroughStep]?,
        expectsClickOnPrimaryShape: Bool,
        isFinalResponse: Bool
    ) {
        self.requestID = requestID
        self.spokenText = spokenText
        self.screenIndex = screenIndex
        self.annotationShapes = annotationShapes
        self.walkthroughSteps = walkthroughSteps
        self.expectsClickOnPrimaryShape = expectsClickOnPrimaryShape
        self.isFinalResponse = isFinalResponse
    }

    /// Tolerant decoding: optional fields default, so older/lighter payloads still parse.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        spokenText = try container.decode(String.self, forKey: .spokenText)
        screenIndex = try container.decodeIfPresent(Int.self, forKey: .screenIndex) ?? 1
        annotationShapes = try container.decodeIfPresent([AnnotationShape].self, forKey: .annotationShapes) ?? []
        walkthroughSteps = try container.decodeIfPresent([WalkthroughStep].self, forKey: .walkthroughSteps)
        expectsClickOnPrimaryShape = try container.decodeIfPresent(Bool.self, forKey: .expectsClickOnPrimaryShape) ?? false
        isFinalResponse = try container.decodeIfPresent(Bool.self, forKey: .isFinalResponse) ?? true
    }
}

enum CompanionEvent {
    case status(requestID: String, text: String)
    case respond(CompanionResponse)
    case confirm(requestID: String, question: String)
    case error(requestID: String?, message: String)
}

// MARK: - Transport protocol

protocol BrainTransport: AnyObject {
    var transportDisplayName: String { get }
    func checkAvailability() async -> Bool
    func sendRequest(_ request: CompanionRequest) async throws
    func sendFollowUp(_ followUp: CompanionFollowUp) async throws
    var companionEvents: AsyncStream<CompanionEvent> { get }
    func cancelRequest(requestID: String) async
}

enum BrainTransportError: LocalizedError {
    case notAvailable(String)
    case badResponseStatus(Int)
    case missingRuntimeFile(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable(let reason): return "Brain transport unavailable: \(reason)"
        case .badResponseStatus(let statusCode): return "Bridge returned HTTP \(statusCode)"
        case .missingRuntimeFile(let path): return "Missing runtime file: \(path)"
        }
    }
}

// MARK: - Wire encoding (CONTRACTS section 2)

extension CompanionRequest {
    /// JSON body for `POST /v1/ask`.
    func bridgeWireJSONData() throws -> Data {
        struct WireScreen: Encodable {
            let screen_index: Int
            let image_path: String
            let width_px: Int
            let height_px: Int
            let label: String
            let is_cursor_screen: Bool
        }
        struct WireApplication: Encodable {
            let name: String?
            let bundle_id: String?
            let window_title: String?
        }
        struct WireBrowserTab: Encodable {
            let url: String?
            let title: String?
        }
        struct WireAsk: Encodable {
            let request_id: String
            let mode: String
            let utterance: String
            let screens: [WireScreen]
            let frontmost_app: WireApplication
            let browser_tab: WireBrowserTab?
            let sent_at: String
        }

        let browserTab: WireBrowserTab? = frontmostBrowserTabURL == nil && frontmostBrowserTabTitle == nil
            ? nil
            : WireBrowserTab(url: frontmostBrowserTabURL, title: frontmostBrowserTabTitle)
        let wireAsk = WireAsk(
            request_id: requestID,
            mode: mode.rawValue,
            utterance: utteranceText,
            screens: capturedScreens.map { screen in
                WireScreen(
                    screen_index: screen.screenIndex,
                    image_path: screen.imageFileURL.path,
                    width_px: screen.imageWidthInPixels,
                    height_px: screen.imageHeightInPixels,
                    label: screen.label,
                    is_cursor_screen: screen.isCursorScreen
                )
            },
            frontmost_app: WireApplication(
                name: frontmostApplicationName,
                bundle_id: frontmostApplicationBundleIdentifier,
                window_title: frontmostWindowTitle
            ),
            browser_tab: browserTab,
            sent_at: ISO8601DateFormatter().string(from: Date())
        )
        return try JSONEncoder().encode(wireAsk)
    }
}

extension CompanionFollowUp {
    /// JSON body for `POST /v1/followup`.
    func bridgeWireJSONData() throws -> Data {
        var body: [String: Any] = ["request_id": requestID]
        switch self {
        case .confirmation(_, let answerIsYes, let utteranceText):
            body["kind"] = "confirmation"
            body["answer"] = answerIsYes ? "yes" : "no"
            body["utterance"] = utteranceText
        case .stepDone(_, let stepIndex):
            body["kind"] = "step_done"
            body["step_index"] = stepIndex
        case .cancel:
            body["kind"] = "cancel"
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}

// MARK: - Runtime files

enum ClickyRuntimePaths {
    static var clickyHomeDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky", isDirectory: true)
    }
    static var bridgeTokenFileURL: URL { clickyHomeDirectoryURL.appendingPathComponent("bridge-token") }
    static var bridgeInfoFileURL: URL { clickyHomeDirectoryURL.appendingPathComponent("bridge.json") }
    static var headlessSessionFileURL: URL { clickyHomeDirectoryURL.appendingPathComponent("headless-session") }
    static var workspaceDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ClickyWorkspace", isDirectory: true)
    }
}

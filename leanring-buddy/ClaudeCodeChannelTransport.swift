//
//  ClaudeCodeChannelTransport.swift
//  leanring-buddy
//
//  Primary BrainTransport: talks to the clicky-channel bridge (bridge/clicky-channel) over
//  loopback HTTP + SSE. Port and bearer token come from ~/.clicky/bridge.json and
//  ~/.clicky/bridge-token (written by the bridge). See docs/fork/CONTRACTS.md section 2.
//

import Foundation

extension CompanionEvent {
    /// Maps one SSE message to an app event. Returns nil for hello/heartbeat/unknown events
    /// and for payloads that don't parse (the stream must never die on a bad event).
    static func fromServerSentEvent(_ serverSentEvent: ServerSentEvent) -> CompanionEvent? {
        guard let payloadData = serverSentEvent.dataText.data(using: .utf8) else { return nil }
        switch serverSentEvent.eventName {
        case "status":
            guard let payload = try? JSONDecoder().decode(StatusPayload.self, from: payloadData) else { return nil }
            return .status(requestID: payload.request_id, text: payload.text)
        case "respond":
            guard let response = try? JSONDecoder().decode(CompanionResponse.self, from: payloadData) else { return nil }
            return .respond(response)
        case "confirm":
            guard let payload = try? JSONDecoder().decode(ConfirmPayload.self, from: payloadData) else { return nil }
            return .confirm(requestID: payload.request_id, question: payload.question)
        case "error":
            guard let payload = try? JSONDecoder().decode(ErrorPayload.self, from: payloadData) else { return nil }
            return .error(requestID: payload.request_id, message: payload.message)
        default:
            return nil
        }
    }

    private struct StatusPayload: Decodable { let request_id: String; let text: String }
    private struct ConfirmPayload: Decodable { let request_id: String; let question: String }
    private struct ErrorPayload: Decodable { let request_id: String?; let message: String }
}

/// Reconnect delay schedule: 0.5s, 1s, 2s, 4s, 8s, then 15s forever.
enum SSEReconnectBackoff {
    static func delayInSeconds(forAttemptNumber attemptNumber: Int) -> Double {
        min(15.0, 0.5 * pow(2.0, Double(max(0, attemptNumber))))
    }
}

final class ClaudeCodeChannelTransport: BrainTransport, @unchecked Sendable {
    let transportDisplayName = "Claude Code channel"

    let companionEvents: AsyncStream<CompanionEvent>
    private let companionEventsContinuation: AsyncStream<CompanionEvent>.Continuation

    private let stateLock = NSLock()
    private var eventStreamTask: Task<Void, Never>?
    private var requestIDsAwaitingFirstEvent = Set<String>()

    private let regularRequestSession: URLSession
    private let eventStreamSession: URLSession

    init() {
        var continuationHolder: AsyncStream<CompanionEvent>.Continuation!
        companionEvents = AsyncStream { continuationHolder = $0 }
        companionEventsContinuation = continuationHolder

        let regularConfiguration = URLSessionConfiguration.ephemeral
        regularConfiguration.timeoutIntervalForRequest = 5
        regularRequestSession = URLSession(configuration: regularConfiguration)

        // Heartbeats arrive every 15 s, so 45 s of silence means the connection is dead.
        let eventStreamConfiguration = URLSessionConfiguration.ephemeral
        eventStreamConfiguration.timeoutIntervalForRequest = 45
        eventStreamConfiguration.timeoutIntervalForResource = 60 * 60 * 24
        eventStreamSession = URLSession(configuration: eventStreamConfiguration)
    }

    deinit {
        eventStreamTask?.cancel()
        companionEventsContinuation.finish()
    }

    // MARK: BrainTransport

    func checkAvailability() async -> Bool {
        guard let health = try? await fetchHealth() else { return false }
        let isAvailable = health.ok && health.channel_registered
        if isAvailable { ensureEventStreamIsRunning() }
        return isAvailable
    }

    func sendRequest(_ request: CompanionRequest) async throws {
        ensureEventStreamIsRunning()
        stateLock.lock()
        requestIDsAwaitingFirstEvent.insert(request.requestID)
        stateLock.unlock()
        try await postJSON(path: "/v1/ask", body: try request.bridgeWireJSONData())
        BridgeLatencyLog.record(requestID: request.requestID, eventName: "submit")
    }

    func sendFollowUp(_ followUp: CompanionFollowUp) async throws {
        try await postJSON(path: "/v1/followup", body: try followUp.bridgeWireJSONData())
    }

    func cancelRequest(requestID: String) async {
        try? await sendFollowUp(.cancel(requestID: requestID))
    }

    // MARK: HTTP

    private struct BridgeConnectionInfo {
        let port: Int
        let token: String
    }

    private struct HealthPayload: Decodable {
        let ok: Bool
        let channel_registered: Bool
    }

    private func loadConnectionInfo() throws -> BridgeConnectionInfo {
        let tokenFileURL = ClickyRuntimePaths.bridgeTokenFileURL
        let infoFileURL = ClickyRuntimePaths.bridgeInfoFileURL
        guard let tokenText = try? String(contentsOf: tokenFileURL, encoding: .utf8) else {
            throw BrainTransportError.missingRuntimeFile(tokenFileURL.path)
        }
        guard let infoData = try? Data(contentsOf: infoFileURL),
              let infoObject = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
              let port = infoObject["port"] as? Int else {
            throw BrainTransportError.missingRuntimeFile(infoFileURL.path)
        }
        return BridgeConnectionInfo(port: port, token: tokenText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func makeRequest(path: String, connectionInfo: BridgeConnectionInfo) -> URLRequest {
        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(connectionInfo.port)\(path)")!)
        urlRequest.setValue("Bearer \(connectionInfo.token)", forHTTPHeaderField: "Authorization")
        return urlRequest
    }

    private func fetchHealth() async throws -> HealthPayload {
        let urlRequest = makeRequest(path: "/v1/health", connectionInfo: try loadConnectionInfo())
        let (data, response) = try await regularRequestSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw BrainTransportError.badResponseStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(HealthPayload.self, from: data)
    }

    private func postJSON(path: String, body: Data) async throws {
        var urlRequest = makeRequest(path: path, connectionInfo: try loadConnectionInfo())
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        let (_, response) = try await regularRequestSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 202 else {
            throw BrainTransportError.badResponseStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    // MARK: SSE

    private func recordLatencyForReceivedEvent(_ companionEvent: CompanionEvent) {
        let eventRequestID: String?
        var isRespond = false
        switch companionEvent {
        case .status(let requestID, _): eventRequestID = requestID
        case .confirm(let requestID, _): eventRequestID = requestID
        case .error(let requestID, _): eventRequestID = requestID
        case .respond(let response):
            eventRequestID = response.requestID
            isRespond = true
        }
        guard let requestID = eventRequestID else { return }
        stateLock.lock()
        let isFirstEvent = requestIDsAwaitingFirstEvent.remove(requestID) != nil
        stateLock.unlock()
        if isFirstEvent { BridgeLatencyLog.record(requestID: requestID, eventName: "first_event") }
        if isRespond { BridgeLatencyLog.record(requestID: requestID, eventName: "respond") }
    }

    private func ensureEventStreamIsRunning() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if eventStreamTask != nil { return }
        eventStreamTask = Task { [weak self] in
            await self?.runEventStreamLoop()
        }
    }

    /// Connects to /v1/events and reconnects with backoff until the transport is deallocated.
    private func runEventStreamLoop() async {
        var consecutiveFailureCount = 0
        while !Task.isCancelled {
            do {
                var urlRequest = makeRequest(path: "/v1/events", connectionInfo: try loadConnectionInfo())
                urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let (byteStream, response) = try await eventStreamSession.bytes(for: urlRequest)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw BrainTransportError.badResponseStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                var parser = ServerSentEventParser()
                var pendingChunk = Data()
                for try await byte in byteStream {
                    pendingChunk.append(byte)
                    // Flush at line boundaries so events are delivered promptly without per-byte parsing.
                    if byte == 0x0A {
                        for serverSentEvent in parser.consume(pendingChunk) {
                            if serverSentEvent.eventName == "hello" { consecutiveFailureCount = 0 }
                            if let companionEvent = CompanionEvent.fromServerSentEvent(serverSentEvent) {
                                recordLatencyForReceivedEvent(companionEvent)
                                companionEventsContinuation.yield(companionEvent)
                            }
                        }
                        pendingChunk.removeAll(keepingCapacity: true)
                    }
                }
            } catch {
                if Task.isCancelled { return }
            }
            let delayInSeconds = SSEReconnectBackoff.delayInSeconds(forAttemptNumber: consecutiveFailureCount)
            consecutiveFailureCount += 1
            try? await Task.sleep(nanoseconds: UInt64(delayInSeconds * 1_000_000_000))
        }
    }
}

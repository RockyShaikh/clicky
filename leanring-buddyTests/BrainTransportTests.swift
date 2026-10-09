import Foundation
import Testing
@testable import leanring_buddy

struct BrainTransportTests {

    private func parseAll(chunks: [String]) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        return chunks.flatMap { parser.consume(Data($0.utf8)) }
    }

    @Test func parsesEventSplitAcrossChunks() {
        let events = parseAll(chunks: ["event: sta", "tus\ndata: {\"a\":", "1}\n", "\n"])
        #expect(events == [ServerSentEvent(eventName: "status", dataText: "{\"a\":1}")])
    }

    @Test func ignoresHeartbeatCommentsAndHandlesCRLF() {
        let events = parseAll(chunks: [": heartbeat\r\n\r\nevent: hello\r\ndata: {}\r\n\r\n"])
        #expect(events == [ServerSentEvent(eventName: "hello", dataText: "{}")])
    }

    @Test func handlesCRLFSplitBetweenChunksAndMultilineData() {
        let events = parseAll(chunks: ["data: one\r", "\ndata: two\r\n\r", "\n"])
        #expect(events == [ServerSentEvent(eventName: "message", dataText: "one\ntwo")])
    }

    @Test func handlesMultibyteCharacterSplitAcrossChunks() {
        let fullBytes = Array("data: caf\u{00E9}\n\n".utf8)
        var parser = ServerSentEventParser()
        let splitIndex = fullBytes.count - 3 // inside the two-byte e-acute
        var events = parser.consume(Data(fullBytes[0..<splitIndex]))
        events += parser.consume(Data(fullBytes[splitIndex...]))
        #expect(events == [ServerSentEvent(eventName: "message", dataText: "caf\u{00E9}")])
    }

    @Test func mapsRespondEventAndDropsMalformedOnes() {
        let respondEvent = ServerSentEvent(
            eventName: "respond",
            dataText: "{\"request_id\":\"r_aaaaaaaaaa\",\"say\":\"hi\",\"screen_index\":1,\"shapes\":[],\"expect_click\":false,\"final\":true}"
        )
        if case .respond(let response)? = CompanionEvent.fromServerSentEvent(respondEvent) {
            #expect(response.spokenText == "hi")
            #expect(response.isFinalResponse)
        } else {
            Issue.record("expected respond event")
        }
        #expect(CompanionEvent.fromServerSentEvent(ServerSentEvent(eventName: "respond", dataText: "not json")) == nil)
        #expect(CompanionEvent.fromServerSentEvent(ServerSentEvent(eventName: "heartbeat", dataText: "{}")) == nil)
    }

    @Test func mapsConfirmAndStatusEvents() {
        let confirmEvent = ServerSentEvent(eventName: "confirm", dataText: "{\"request_id\":\"r_a\",\"question\":\"send it?\"}")
        if case .confirm(let requestID, let question)? = CompanionEvent.fromServerSentEvent(confirmEvent) {
            #expect(requestID == "r_a")
            #expect(question == "send it?")
        } else {
            Issue.record("expected confirm event")
        }
    }

    @Test func reconnectBackoffGrowsAndCaps() {
        #expect(SSEReconnectBackoff.delayInSeconds(forAttemptNumber: 0) == 0.5)
        #expect(SSEReconnectBackoff.delayInSeconds(forAttemptNumber: 2) == 2.0)
        #expect(SSEReconnectBackoff.delayInSeconds(forAttemptNumber: 20) == 15.0)
    }

    @Test func headlessOutputParsesStructuredOutputAndSessionID() throws {
        let output = "{\"session_id\":\"abc\",\"structured_output\":{\"say\":\"over here\",\"shapes\":[]}}"
        let parsed = try HeadlessClaudeOutputParser.parse(outputData: Data(output.utf8), requestID: "r_bbbbbbbbbb")
        #expect(parsed.sessionID == "abc")
        #expect(parsed.response.requestID == "r_bbbbbbbbbb")
        #expect(parsed.response.spokenText == "over here")
    }

    @Test func askWireBodyUsesContractKeys() throws {
        let request = CompanionRequest(
            requestID: "r_cccccccccc",
            utteranceText: "where",
            mode: .doTask,
            capturedScreens: [
                CapturedScreenForRequest(
                    screenIndex: 1,
                    imageFileURL: URL(fileURLWithPath: "/tmp/x.jpg"),
                    imageWidthInPixels: 1280,
                    imageHeightInPixels: 831,
                    displayFrameInAppKitGlobalPoints: .zero,
                    isCursorScreen: true,
                    label: "cursor screen"
                )
            ],
            frontmostApplicationName: "Notes",
            frontmostApplicationBundleIdentifier: "com.apple.Notes",
            frontmostWindowTitle: nil,
            frontmostBrowserTabURL: nil,
            frontmostBrowserTabTitle: nil
        )
        let object = try #require(JSONSerialization.jsonObject(with: request.bridgeWireJSONData()) as? [String: Any])
        #expect(object["mode"] as? String == "do")
        #expect(object["request_id"] as? String == "r_cccccccccc")
        #expect(object["browser_tab"] == nil)
        let screens = try #require(object["screens"] as? [[String: Any]])
        #expect(screens[0]["width_px"] as? Int == 1280)
    }
}

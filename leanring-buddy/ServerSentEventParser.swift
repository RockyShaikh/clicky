//
//  ServerSentEventParser.swift
//  leanring-buddy
//
//  Incremental text/event-stream parser. Feed it raw bytes in whatever chunks the network
//  delivers; it returns complete events. Handles chunk splits (even mid-UTF-8 character),
//  CRLF/LF/CR line endings, comment lines (": ...", used for heartbeats), and multi-line data.
//

import Foundation

struct ServerSentEvent: Equatable {
    /// "message" when the stream sent no `event:` field.
    let eventName: String
    let dataText: String
}

struct ServerSentEventParser {
    private var pendingBytes = Data()
    private var currentEventName: String?
    private var currentDataLines: [String] = []
    private var previousChunkEndedWithCarriageReturn = false

    mutating func consume(_ newBytes: Data) -> [ServerSentEvent] {
        var bytes = newBytes
        // A CRLF split across chunks: the LF belongs to the CR we already treated as a line end.
        if previousChunkEndedWithCarriageReturn, bytes.first == 0x0A {
            bytes = bytes.dropFirst()
        }
        if !bytes.isEmpty {
            previousChunkEndedWithCarriageReturn = false
        }
        pendingBytes.append(bytes)

        var completedEvents: [ServerSentEvent] = []
        while let lineEndIndex = pendingBytes.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineBytes = pendingBytes[pendingBytes.startIndex..<lineEndIndex]
            let lineEndByte = pendingBytes[lineEndIndex]
            var nextStartIndex = pendingBytes.index(after: lineEndIndex)
            if lineEndByte == 0x0D {
                if nextStartIndex < pendingBytes.endIndex {
                    if pendingBytes[nextStartIndex] == 0x0A {
                        nextStartIndex = pendingBytes.index(after: nextStartIndex)
                    }
                } else {
                    previousChunkEndedWithCarriageReturn = true
                }
            }
            let lineText = String(decoding: lineBytes, as: UTF8.self)
            pendingBytes = Data(pendingBytes[nextStartIndex...])

            if let completedEvent = processLine(lineText) {
                completedEvents.append(completedEvent)
            }
        }
        return completedEvents
    }

    private mutating func processLine(_ line: String) -> ServerSentEvent? {
        if line.isEmpty {
            // Blank line dispatches the event (if any data was collected).
            defer {
                currentEventName = nil
                currentDataLines = []
            }
            guard !currentDataLines.isEmpty else { return nil }
            return ServerSentEvent(
                eventName: currentEventName ?? "message",
                dataText: currentDataLines.joined(separator: "\n")
            )
        }
        if line.hasPrefix(":") { return nil }

        let fieldName: String
        var fieldValue: String
        if let colonIndex = line.firstIndex(of: ":") {
            fieldName = String(line[line.startIndex..<colonIndex])
            fieldValue = String(line[line.index(after: colonIndex)...])
            if fieldValue.hasPrefix(" ") { fieldValue.removeFirst() }
        } else {
            fieldName = line
            fieldValue = ""
        }
        switch fieldName {
        case "event": currentEventName = fieldValue
        case "data": currentDataLines.append(fieldValue)
        default: break // id, retry: unused
        }
        return nil
    }
}

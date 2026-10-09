//
//  BridgeLatencyLog.swift
//  leanring-buddy
//
//  Writes latency lines per docs/fork/TESTING.md to ~/.clicky/logs/app-YYYY-MM-DD.log:
//  `<ISO8601 UTC ms> latency request_id=<r_...> event=<name> [key=value ...]`.
//  WS3 emits `submit`, `first_event` and `respond`.
//

import Foundation

enum BridgeLatencyLog {
    private static let writeQueue = DispatchQueue(label: "clicky.latency-log")

    static func formattedLine(date: Date, requestID: String, eventName: String, extraFields: String = "") -> String {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let suffix = extraFields.isEmpty ? "" : " \(extraFields)"
        return "\(timestampFormatter.string(from: date)) latency request_id=\(requestID) event=\(eventName)\(suffix)\n"
    }

    static func record(requestID: String, eventName: String, extraFields: String = "") {
        let now = Date()
        let line = formattedLine(date: now, requestID: requestID, eventName: eventName, extraFields: extraFields)
        writeQueue.async {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.timeZone = TimeZone(identifier: "UTC")
            let logsDirectoryURL = ClickyRuntimePaths.clickyHomeDirectoryURL.appendingPathComponent("logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
            let logFileURL = logsDirectoryURL.appendingPathComponent("app-\(dayFormatter.string(from: now)).log")
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            }
            guard let fileHandle = try? FileHandle(forWritingTo: logFileURL),
                  let lineData = line.data(using: .utf8) else { return }
            defer { try? fileHandle.close() }
            _ = try? fileHandle.seekToEnd()
            try? fileHandle.write(contentsOf: lineData)
        }
    }
}

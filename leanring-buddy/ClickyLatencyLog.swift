//
//  ClickyLatencyLog.swift
//  leanring-buddy
//
//  Appends latency lines (CONTRACTS section 9) to ~/.clicky/logs/app-YYYY-MM-DD.log:
//  <ISO8601 UTC ms> latency request_id=<id> event=<name> [k=v ...]
//  Usable from any thread; formatting and file I/O happen on a private serial queue.
//  Reusable: ClickyLatencyLog.record(requestID:event:extraFields:)
//

import Foundation

nonisolated enum ClickyLatencyLog {
    /// Request ID minted by the most recent `wake`; the lead uses it for the whole summon.
    static var latestWakeRequestID: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedLatestWakeRequestID
    }

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var storedLatestWakeRequestID: String?
    private static let writeQueue = DispatchQueue(label: "com.clicky.latency-log", qos: .utility)

    /// Touched only on `writeQueue`.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Mints a request ID, records `wake` with it, and returns it.
    @discardableResult
    static func recordWake(triggerDescription: String) -> String {
        let requestID = CompanionRequestIdentifier.makeNewRequestID()
        stateLock.lock()
        storedLatestWakeRequestID = requestID
        stateLock.unlock()
        record(requestID: requestID, event: "wake", extraFields: ["trigger": triggerDescription])
        return requestID
    }

    static func record(requestID: String, event: String, extraFields: [String: String] = [:]) {
        let eventDate = Date()   // captured now, formatted later off-thread
        writeQueue.async {
            let fieldText = extraFields.sorted { $0.key < $1.key }.map { " \($0.key)=\($0.value)" }.joined()
            let line = "\(timestampFormatter.string(from: eventDate)) latency request_id=\(requestID) event=\(event)\(fieldText)\n"
            append(line: line, eventDate: eventDate)
        }
    }

    private static func append(line: String, eventDate: Date) {
        let logsDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicky/logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logsDirectoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let logFileURL = logsDirectoryURL.appendingPathComponent("app-\(dayFormatter.string(from: eventDate)).log")
        guard let lineData = line.data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let fileHandle = try? FileHandle(forWritingTo: logFileURL) else { return }
        defer { try? fileHandle.close() }
        _ = try? fileHandle.seekToEnd()
        try? fileHandle.write(contentsOf: lineData)
    }
}

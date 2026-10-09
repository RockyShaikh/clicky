//
//  RequestScreenCaptureService.swift
//  leanring-buddy
//
//  Implements ScreenCaptureForRequestProvider (CONTRACTS section 6). Captures the cursor
//  screen only by default, writes JPEGs to ~/.clicky/shots/<request_id>-s<N>.jpg
//  (long edge 1280, newest 50 files kept) and returns CapturedScreenForRequest values.
//

import AppKit
import Foundation
import os
import ScreenCaptureKit

struct CapturedScreenForRequest: Codable, Equatable {
    let screenIndex: Int
    let imageFileURL: URL
    let imageWidthInPixels: Int
    let imageHeightInPixels: Int
    let displayFrameInAppKitGlobalPoints: CGRect   // NSScreen.frame
    let isCursorScreen: Bool
    let label: String
}

protocol ScreenCaptureForRequestProvider: AnyObject {
    func captureScreensForNewRequest(requestID: String) async throws -> [CapturedScreenForRequest]
}

enum RequestScreenCaptureError: LocalizedError {
    case captureBlockedByPrivacyGuard
    case noDisplayAvailable
    case jpegEncodingFailed

    var errorDescription: String? {
        switch self {
        case .captureBlockedByPrivacyGuard: return "Capture skipped: a password manager or banking app is frontmost."
        case .noDisplayAvailable: return "No display available for capture."
        case .jpegEncodingFailed: return "Could not encode the screenshot as JPEG."
        }
    }
}

/// Pure sizing math, separate so it can be unit tested without ScreenCaptureKit.
enum CaptureImageSizing {
    static let longEdgeInPixels = 1280

    /// Scales so the long edge is exactly `longEdgeInPixels`, keeping aspect ratio.
    /// Matches the existing capture utility, which also always scales to 1280.
    static func targetPixelSize(displayWidth: Int, displayHeight: Int) -> (width: Int, height: Int) {
        guard displayWidth > 0, displayHeight > 0 else { return (longEdgeInPixels, longEdgeInPixels) }
        if displayWidth >= displayHeight {
            let height = Int((Double(longEdgeInPixels) * Double(displayHeight) / Double(displayWidth)).rounded())
            return (longEdgeInPixels, max(1, height))
        } else {
            let width = Int((Double(longEdgeInPixels) * Double(displayWidth) / Double(displayHeight)).rounded())
            return (max(1, width), longEdgeInPixels)
        }
    }
}

/// Keeps only the newest N screenshot files in a directory.
enum ShotFileRotation {
    static let maximumFileCount = 50

    /// Returns the files to delete: everything beyond the newest `maximumFileCount`.
    static func filesToDelete(
        from filesWithModificationDates: [(url: URL, modificationDate: Date)],
        maximumFileCount: Int = ShotFileRotation.maximumFileCount
    ) -> [URL] {
        let newestFirst = filesWithModificationDates.sorted { $0.modificationDate > $1.modificationDate }
        return newestFirst.dropFirst(maximumFileCount).map { $0.url }
    }

    static func rotate(directoryURL: URL, maximumFileCount: Int = ShotFileRotation.maximumFileCount) {
        let fileManager = FileManager.default
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let filesWithModificationDates: [(url: URL, modificationDate: Date)] = fileURLs
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .map { fileURL in
                let modificationDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (fileURL, modificationDate)
            }

        for fileURLToDelete in filesToDelete(from: filesWithModificationDates, maximumFileCount: maximumFileCount) {
            try? fileManager.removeItem(at: fileURLToDelete)
        }
    }
}

nonisolated enum CompanionRequestIdentifier {
    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    /// "r_" + 10 lowercase base32 characters (CONTRACTS section 1).
    static func makeNewRequestID() -> String {
        let randomCharacters = (0..<10).map { _ in base32Alphabet.randomElement()! }
        return "r_" + String(randomCharacters)
    }

    static func isValid(_ requestID: String) -> Bool {
        guard requestID.hasPrefix("r_"), requestID.count == 12 else { return false }
        return requestID.dropFirst(2).allSatisfy { base32Alphabet.contains($0) }
    }
}

/// Latency signposts for the summon path (category `latency`), viewable in Instruments.
enum SummonLatencySignposter {
    static let log = OSLog(subsystem: "com.clicky.fork", category: "latency")
    static let logger = Logger(subsystem: "com.clicky.fork", category: "latency")

    static func event(_ name: StaticString, detail: String = "") {
        os_signpost(.event, log: log, name: name, "%{public}s", detail)
        logger.info("\(String(describing: name), privacy: .public) \(detail, privacy: .public)")
    }
}

@MainActor
final class RequestScreenCaptureService: ScreenCaptureForRequestProvider {
    static let captureAllScreensUserDefaultsKey = "clickyCaptureAllScreens"

    /// Duration of the most recent capture, for logging and the spike harness.
    private(set) var lastCaptureDurationInMilliseconds: Double = 0

    private let shotsDirectoryURL: URL
    private let userDefaults: UserDefaults

    init(
        shotsDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicky/shots", isDirectory: true),
        userDefaults: UserDefaults = .standard
    ) {
        self.shotsDirectoryURL = shotsDirectoryURL
        self.userDefaults = userDefaults
    }

    func captureScreensForNewRequest(requestID: String) async throws -> [CapturedScreenForRequest] {
        if PrivacyCaptureGuard.isCaptureCurrentlyDenied(userDefaults: userDefaults) {
            throw RequestScreenCaptureError.captureBlockedByPrivacyGuard
        }

        let captureStartTime = DispatchTime.now()
        SummonLatencySignposter.event("capture_start", detail: requestID)

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !shareableContent.displays.isEmpty else { throw RequestScreenCaptureError.noDisplayAvailable }

        let mouseLocation = NSEvent.mouseLocation

        // Own windows (dim layer, panels, overlay) are excluded so they can never appear in a shot.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownWindows = shareableContent.windows.filter {
            $0.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // SCDisplay.frame is CG coordinates; NSScreen.frame and NSEvent.mouseLocation are AppKit.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[displayID] = screen
            }
        }

        func appKitFrame(for display: SCDisplay) -> CGRect {
            nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
        }

        // Cursor screen first, so screen_index 1 is always the cursor screen.
        let sortedDisplays = shareableContent.displays.sorted { displayA, displayB in
            let aContainsCursor = appKitFrame(for: displayA).contains(mouseLocation)
            let bContainsCursor = appKitFrame(for: displayB).contains(mouseLocation)
            return aContainsCursor && !bContainsCursor
        }

        let shouldCaptureAllScreens = userDefaults.bool(forKey: Self.captureAllScreensUserDefaultsKey)
        let displaysToCapture = shouldCaptureAllScreens ? sortedDisplays : Array(sortedDisplays.prefix(1))

        try FileManager.default.createDirectory(at: shotsDirectoryURL, withIntermediateDirectories: true)

        var capturedScreens: [CapturedScreenForRequest] = []
        for (displayIndex, display) in displaysToCapture.enumerated() {
            let displayFrame = appKitFrame(for: display)
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let targetPixelSize = CaptureImageSizing.targetPixelSize(
                displayWidth: display.width, displayHeight: display.height)
            let configuration = SCStreamConfiguration()
            configuration.width = targetPixelSize.width
            configuration.height = targetPixelSize.height

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: ownWindows),
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                throw RequestScreenCaptureError.jpegEncodingFailed
            }

            let screenIndex = displayIndex + 1
            let imageFileURL = shotsDirectoryURL.appendingPathComponent("\(requestID)-s\(screenIndex).jpg")
            try jpegData.write(to: imageFileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageFileURL.path)

            let label: String
            if sortedDisplays.count == 1 {
                label = "user's screen (cursor is here)"
            } else if isCursorScreen {
                label = "cursor screen (primary focus)"
            } else {
                label = "screen \(screenIndex) of \(sortedDisplays.count) - secondary screen"
            }

            capturedScreens.append(CapturedScreenForRequest(
                screenIndex: screenIndex,
                imageFileURL: imageFileURL,
                imageWidthInPixels: cgImage.width,
                imageHeightInPixels: cgImage.height,
                displayFrameInAppKitGlobalPoints: displayFrame,
                isCursorScreen: isCursorScreen,
                label: label
            ))
        }

        ShotFileRotation.rotate(directoryURL: shotsDirectoryURL)

        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - captureStartTime.uptimeNanoseconds
        lastCaptureDurationInMilliseconds = Double(elapsedNanoseconds) / 1_000_000
        SummonLatencySignposter.event("capture_done", detail: "\(requestID) \(Int(lastCaptureDurationInMilliseconds)) ms")
        ClickyLatencyLog.record(requestID: requestID, event: "capture_done", extraFields: ["screens": String(capturedScreens.count)])

        return capturedScreens
    }
}

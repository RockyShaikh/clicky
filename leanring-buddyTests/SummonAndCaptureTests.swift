//
//  SummonAndCaptureTests.swift
//  leanring-buddyTests
//
//  Unit tests for WS1 types: capture sizing, shot rotation, tap detection, wake phrase
//  matching, privacy guard, request IDs, dim opacity clamping.
//

import AppKit
import Foundation
import Testing
@testable import leanring_buddy

struct SummonAndCaptureTests {

    @Test func landscapeDisplayIsScaledToLongEdge1280KeepingAspect() {
        let size = CaptureImageSizing.targetPixelSize(displayWidth: 3024, displayHeight: 1964)
        #expect(size.width == 1280)
        #expect(size.height == 831)
    }

    @Test func portraitDisplayIsScaledToLongEdge1280() {
        let size = CaptureImageSizing.targetPixelSize(displayWidth: 1080, displayHeight: 1920)
        #expect(size.height == 1280)
        #expect(size.width == 720)
    }

    @Test func rotationDeletesOnlyOldestBeyondLimit() {
        let now = Date()
        let files = (0..<55).map { index in
            (url: URL(fileURLWithPath: "/tmp/f\(index).jpg"), modificationDate: now.addingTimeInterval(Double(index)))
        }
        let deleted = ShotFileRotation.filesToDelete(from: files, maximumFileCount: 50)
        #expect(deleted.count == 5)
        #expect(Set(deleted.map { $0.lastPathComponent }) == Set((0..<5).map { "f\($0).jpg" }))
    }

    @Test func rotationOnRealDirectoryKeepsNewestFiles() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-rotation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        for index in 0..<8 {
            let fileURL = directoryURL.appendingPathComponent("r_x-s\(index).jpg")
            try Data([0]).write(to: fileURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(index))], ofItemAtPath: fileURL.path)
        }
        ShotFileRotation.rotate(directoryURL: directoryURL, maximumFileCount: 3)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).sorted()
        #expect(remaining == ["r_x-s5.jpg", "r_x-s6.jpg", "r_x-s7.jpg"])
    }

    @Test func quickControlOptionTapIsDetected() {
        var detector = ControlOptionTapDetector()
        #expect(!detector.handleModifierFlagsChanged(modifierFlags: [.control], timestampInSeconds: 0))
        #expect(!detector.handleModifierFlagsChanged(modifierFlags: [.control, .option], timestampInSeconds: 0.02))
        #expect(detector.handleModifierFlagsChanged(modifierFlags: [.control], timestampInSeconds: 0.12))
        #expect(!detector.handleModifierFlagsChanged(modifierFlags: [], timestampInSeconds: 0.14))
    }

    @Test func slowHoldIsNotATap() {
        var detector = ControlOptionTapDetector()
        _ = detector.handleModifierFlagsChanged(modifierFlags: [.control, .option], timestampInSeconds: 0)
        #expect(!detector.handleModifierFlagsChanged(modifierFlags: [], timestampInSeconds: 0.4))
    }

    @Test func otherKeyDuringChordIsNotATap() {
        var detector = ControlOptionTapDetector()
        _ = detector.handleModifierFlagsChanged(modifierFlags: [.control, .option], timestampInSeconds: 0)
        detector.handleKeyDown()
        #expect(!detector.handleModifierFlagsChanged(modifierFlags: [], timestampInSeconds: 0.1))
    }

    @Test func addingShiftDuringChordIsNotATap() {
        var detector = ControlOptionTapDetector()
        _ = detector.handleModifierFlagsChanged(modifierFlags: [.control, .option], timestampInSeconds: 0)
        #expect(!detector.handleModifierFlagsChanged(modifierFlags: [.control, .option, .shift], timestampInSeconds: 0.05))
        #expect(!detector.handleModifierFlagsChanged(modifierFlags: [], timestampInSeconds: 0.1))
    }

    @Test func wakePhraseMatching() {
        #expect(WakeWordPhraseMatcher.containsWakePhrase(in: "Hey Clicky"))
        #expect(WakeWordPhraseMatcher.containsWakePhrase(in: "ok so hey, clicky what is this"))
        #expect(WakeWordPhraseMatcher.containsWakePhrase(in: "hey click e"))
        #expect(!WakeWordPhraseMatcher.containsWakePhrase(in: "the clicky keyboard is loud"))
        #expect(!WakeWordPhraseMatcher.containsWakePhrase(in: "hey there"))
        #expect(!WakeWordPhraseMatcher.containsWakePhrase(in: "clicky"))
    }

    @Test func privacyGuardMatchesExactAndPrefixEntries() {
        let denied = PrivacyCaptureGuard.defaultDeniedBundleIdentifiers
        #expect(PrivacyCaptureGuard.isCaptureDenied(forFrontmostBundleIdentifier: "com.1password.1password", deniedBundleIdentifiers: denied))
        #expect(PrivacyCaptureGuard.isCaptureDenied(forFrontmostBundleIdentifier: "com.apple.keychainaccess", deniedBundleIdentifiers: denied))
        #expect(!PrivacyCaptureGuard.isCaptureDenied(forFrontmostBundleIdentifier: "com.apple.Notes", deniedBundleIdentifiers: denied))
        #expect(!PrivacyCaptureGuard.isCaptureDenied(forFrontmostBundleIdentifier: nil, deniedBundleIdentifiers: denied))
    }

    @Test func requestIdentifierFormat() {
        for _ in 0..<50 {
            #expect(CompanionRequestIdentifier.isValid(CompanionRequestIdentifier.makeNewRequestID()))
        }
        #expect(!CompanionRequestIdentifier.isValid("r_ABCDE12345"))
    }

    @Test func dimOpacityIsClampedTo15Through45Percent() {
        #expect(CaptureDimLayerState.clampedDimOpacity(percent: 5) == 0.15)
        #expect(CaptureDimLayerState.clampedDimOpacity(percent: 30) == 0.30)
        #expect(CaptureDimLayerState.clampedDimOpacity(percent: 90) == 0.45)
    }
}

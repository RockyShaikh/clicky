//
//  SingleInstanceGuard.swift
//  leanring-buddy
//
//  An orphaned dev build can survive an Xcode stop and keep its wake-word listener running,
//  doubling mic use. At launch, terminate any other running copy with our bundle identifier.
//

import AppKit
import Foundation

enum SingleInstanceGuard {
    static func terminateOtherRunningInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentProcessIdentifier }
        for staleInstance in otherInstances {
            print("🎯 Clicky: terminating stale instance pid \(staleInstance.processIdentifier)")
            if !staleInstance.terminate() { staleInstance.forceTerminate() }
        }
    }
}

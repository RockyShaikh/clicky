//
//  PrivacyCaptureGuard.swift
//  leanring-buddy
//
//  Decides whether a screen capture is allowed right now. Capture is skipped
//  when a password manager or banking app is the frontmost application, so
//  sensitive screens never get written to ~/.clicky/shots or sent to Claude.
//

import AppKit
import Foundation

enum PrivacyCaptureGuard {
    /// UserDefaults key holding the user-editable [String] of bundle identifiers to never capture.
    static let deniedBundleIdentifiersUserDefaultsKey = "clickyCaptureDeniedBundleIdentifiers"

    /// Used when the user has not customized the list. Entries ending in "." match any
    /// bundle identifier with that prefix (e.g. all 1Password variants).
    static let defaultDeniedBundleIdentifiers: [String] = [
        "com.1password.",
        "com.agilebits.",
        "com.bitwarden.",
        "com.lastpass.",
        "com.dashlane.",
        "org.keepassxc.",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.nordsec.nordpass",
        "com.enpass.",
        "com.proton.pass",
    ]

    static func deniedBundleIdentifiers(userDefaults: UserDefaults = .standard) -> [String] {
        userDefaults.stringArray(forKey: deniedBundleIdentifiersUserDefaultsKey) ?? defaultDeniedBundleIdentifiers
    }

    static func isCaptureDenied(
        forFrontmostBundleIdentifier frontmostBundleIdentifier: String?,
        deniedBundleIdentifiers: [String]
    ) -> Bool {
        guard let frontmostBundleIdentifier else { return false }
        let lowercasedFrontmostBundleIdentifier = frontmostBundleIdentifier.lowercased()
        return deniedBundleIdentifiers.contains { deniedEntry in
            let lowercasedDeniedEntry = deniedEntry.lowercased()
            if lowercasedDeniedEntry.hasSuffix(".") {
                return lowercasedFrontmostBundleIdentifier.hasPrefix(lowercasedDeniedEntry)
            }
            return lowercasedFrontmostBundleIdentifier == lowercasedDeniedEntry
        }
    }

    /// True when the frontmost app right now is on the denylist.
    static func isCaptureCurrentlyDenied(userDefaults: UserDefaults = .standard) -> Bool {
        isCaptureDenied(
            forFrontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            deniedBundleIdentifiers: deniedBundleIdentifiers(userDefaults: userDefaults)
        )
    }
}

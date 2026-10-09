//
//  DoModeRequestClassifier.swift
//  leanring-buddy
//
//  Do mode helpers (WS5): a cheap keyword guess at whether an utterance asks Clicky to ACT in the
//  browser (so the request carries `mode: do` and the headless transport can say it cannot do it),
//  and the active Chrome tab lookup used to fill `browser_tab` in requests.
//

import AppKit
import Foundation

enum DoModeRequestClassifier {
    private static let actionPhrases: [String] = [
        "fill", "sign me up", "sign up", "log me in", "sign in", "check out",
        "checkout", "submit", "click the", "click on", "press the", "type in", "type my", "enter my",
        "book ", "order ", "buy ", "purchase", "add to cart", "send this", "send it", "send an email",
        "post this", "delete ", "unsubscribe", "apply to", "register me", "on this page for me"
    ]

    static func utteranceLooksLikeDoRequest(_ utteranceText: String) -> Bool {
        let lowercasedUtterance = " " + utteranceText.lowercased() + " "
        return actionPhrases.contains { lowercasedUtterance.contains($0) }
    }

    static let headlessCannotDoWebActionsSpokenMessage =
        "I can't do things in your browser in headless mode. Start the Clicky session with Chrome, then ask me again."
}

struct FrontmostBrowserTab: Equatable {
    let url: String
    let title: String

    static let chromeBundleIdentifiers: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary"]

    /// Same AppleScript as scripts/frontmost-browser-tab.sh. Returns nil when Chrome is not
    /// frontmost, has no window, or Automation permission was not granted; the caller then just
    /// omits `browser_tab`.
    static func currentTab(frontmostBundleIdentifier: String?) -> FrontmostBrowserTab? {
        guard let frontmostBundleIdentifier, chromeBundleIdentifiers.contains(frontmostBundleIdentifier) else { return nil }
        let applicationName = frontmostBundleIdentifier == "com.google.Chrome.canary" ? "Google Chrome Canary" : "Google Chrome"
        let scriptSource = """
        tell application "\(applicationName)"
            if (count of windows) is 0 then return ""
            set activeTabURL to URL of active tab of front window
            set activeTabTitle to title of active tab of front window
            return activeTabURL & linefeed & activeTabTitle
        end tell
        """
        var scriptError: NSDictionary?
        guard let resultDescriptor = NSAppleScript(source: scriptSource)?.executeAndReturnError(&scriptError),
              let resultText = resultDescriptor.stringValue, !resultText.isEmpty else { return nil }
        let lines = resultText.components(separatedBy: "\n")
        return FrontmostBrowserTab(url: lines[0], title: lines.dropFirst().joined(separator: "\n"))
    }
}

//
//  ClickyClaudeConfiguration.swift
//  leanring-buddy
//
//  Which Claude Code login Clicky's `claude` processes use. Clicky never uses the default
//  ~/.claude login (it may be a Team org); it always runs against a separate config dir that
//  holds a personal Pro login, set once with `scripts/clicky-session.sh login`.
//

import Foundation

enum ClickyClaudeConfiguration {
    static let configDirectoryUserDefaultsKey = "clickyClaudeConfigDirectory"
    static let configDirectoryEnvironmentVariableName = "CLICKY_CLAUDE_CONFIG_DIR"

    enum LoginState: Equatable {
        case loggedIn
        case configDirectoryMissing(path: String)
        case notLoggedIn(path: String)

        /// Human-readable reason, nil when logged in.
        var unavailableReason: String? {
            switch self {
            case .loggedIn:
                return nil
            case .configDirectoryMissing(let path):
                return "Personal Claude config dir \(path) does not exist. Run scripts/clicky-session.sh login."
            case .notLoggedIn(let path):
                return "No personal Claude login in \(path). Run scripts/clicky-session.sh login and use /login."
            }
        }
    }

    /// UserDefaults value, then env var, then `$HOME/.claude-personal`.
    static func configDirectoryURL(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configuredPath = userDefaults.string(forKey: configDirectoryUserDefaultsKey), !configuredPath.isEmpty {
            return URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath)
        }
        if let environmentPath = environment[configDirectoryEnvironmentVariableName], !environmentPath.isEmpty {
            return URL(fileURLWithPath: (environmentPath as NSString).expandingTildeInPath)
        }
        return homeDirectoryURL.appendingPathComponent(".claude-personal")
    }

    /// Looks for a credentials file or an `oauthAccount` entry in the config dir's `.claude.json`.
    /// Never reads or returns secret values.
    static func loginState(configDirectoryURL: URL = configDirectoryURL()) -> LoginState {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: configDirectoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .configDirectoryMissing(path: configDirectoryURL.path)
        }
        if fileManager.fileExists(atPath: configDirectoryURL.appendingPathComponent(".credentials.json").path) {
            return .loggedIn
        }
        let globalConfigFileURL = configDirectoryURL.appendingPathComponent(".claude.json")
        if let globalConfigText = try? String(contentsOf: globalConfigFileURL, encoding: .utf8),
           globalConfigText.contains("\"oauthAccount\"") {
            return .loggedIn
        }
        return .notLoggedIn(path: configDirectoryURL.path)
    }

    /// Environment for any child `claude`: personal config dir, no API key (it would bill the API).
    static func childProcessEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        configDirectoryURL: URL = configDirectoryURL()
    ) -> [String: String] {
        var childEnvironment = base
        childEnvironment.removeValue(forKey: "ANTHROPIC_API_KEY")
        childEnvironment["CLAUDE_CONFIG_DIR"] = configDirectoryURL.path
        return childEnvironment
    }
}

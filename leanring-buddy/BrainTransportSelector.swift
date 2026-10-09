//
//  BrainTransportSelector.swift
//  leanring-buddy
//
//  Picks the best available BrainTransport: channel -> headless. The third tier (the upstream
//  direct Claude API flow) lives in CompanionManager, so `selectTransport()` returns nil when
//  neither Claude Code transport works and the lead's coordinator falls back to it.
//

import Foundation

final class BrainTransportSelector {
    private let channelTransport: BrainTransport
    private let headlessTransport: BrainTransport

    init(
        channelTransport: BrainTransport = ClaudeCodeChannelTransport(),
        headlessTransport: BrainTransport = ClaudeCodeHeadlessTransport()
    ) {
        self.channelTransport = channelTransport
        self.headlessTransport = headlessTransport
    }

    /// Checked per request (cheap loopback health call) so killing the tmux session switches
    /// to headless on the next request without restarting the app.
    func selectTransport() async -> BrainTransport? {
        if await channelTransport.checkAvailability() { return channelTransport }
        if await headlessTransport.checkAvailability() { return headlessTransport }
        return nil
    }

    /// Both transports' events, merged, so a consumer can listen once regardless of which transport answered.
    var mergedCompanionEvents: AsyncStream<CompanionEvent> {
        let channelEvents = channelTransport.companionEvents
        let headlessEvents = headlessTransport.companionEvents
        return AsyncStream { continuation in
            let forwardingTasks = [channelEvents, headlessEvents].map { eventStream in
                Task {
                    for await companionEvent in eventStream { continuation.yield(companionEvent) }
                }
            }
            continuation.onTermination = { _ in forwardingTasks.forEach { $0.cancel() } }
        }
    }
}

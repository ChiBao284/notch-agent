//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    /// Plan usage limits ("Your usage limits") — account-wide, so it's kept
    /// here rather than on any one SessionState.
    ///
    /// Two sources feed this, both reporting the same numbers: any session's
    /// statusLine tick, and a periodic fetch straight from Anthropic. The fetch
    /// is what makes the readout work at all under Claude Code Desktop, which
    /// never invokes a statusLine.
    @Published var accountRateLimits: RateLimitInfo?

    private var cancellables = Set<AnyCancellable>()
    private var usagePollTask: Task<Void, Never>?
    private var lastUsageFetch: Date?

    /// How often to re-ask Anthropic. The windows move slowly — a 5-hour and a
    /// weekly bucket — so this is about staying fresh, not being live.
    private static let usagePollInterval: Duration = .seconds(300)

    /// Floor between on-demand refreshes triggered by opening the notch.
    ///
    /// Matches the poll interval rather than sitting well under it: the windows
    /// move over hours, and asking on every open is what got the endpoint to
    /// start answering 429.
    private static let usageRefreshThrottle: TimeInterval = 300

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        // Start periodic status rechecking
        Task {
            await SessionStore.shared.startPeriodicStatusCheck()
        }

        startUsagePolling()

        HookSocketServer.shared.start(
            onEvent: { [weak self] event in
                if event.event == "StatusLine", let rateLimits = event.rateLimits {
                    Task { @MainActor in
                        self?.accountRateLimits = rateLimits
                    }
                }

                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
        usagePollTask?.cancel()
        usagePollTask = nil
        Task {
            await SessionStore.shared.stopPeriodicStatusCheck()
        }
    }

    // MARK: - Plan Usage

    /// Poll Anthropic for the account's usage until monitoring stops.
    ///
    /// A failed poll leaves the last known numbers in place — a dropped network
    /// or a token Claude Code hasn't refreshed yet shouldn't blank the readout.
    private func startUsagePolling() {
        usagePollTask?.cancel()
        usagePollTask = Task { [weak self] in
            while !Task.isCancelled {
                let usage = await ClaudeUsageFetcher.shared.fetchUsage()
                guard let self else { return }
                self.lastUsageFetch = Date()
                if let usage {
                    self.accountRateLimits = usage
                }

                do {
                    try await Task.sleep(for: Self.usagePollInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// Refresh usage now, without waiting for the next poll — used when the
    /// panel is about to be shown.
    ///
    /// Throttled, because opening and closing the notch a few times in a row
    /// shouldn't turn into a burst of requests for numbers that barely move.
    func refreshUsage() {
        let now = Date()
        if let lastFetch = lastUsageFetch, now.timeIntervalSince(lastFetch) < Self.usageRefreshThrottle {
            return
        }
        lastUsageFetch = now

        Task { [weak self] in
            if let usage = await ClaudeUsageFetcher.shared.fetchUsage() {
                self?.accountRateLimits = usage
            }
        }
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "deny",
                reason: reason
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}

//
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    /// Height the session rows actually occupy, so the blank space underneath
    /// can be handed to the open-Claude backdrop instead of the scroll view.
    @State private var listContentHeight: CGFloat = 0

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            instancesList
        }
    }

    /// Session the backdrop falls back to when Claude Desktop isn't installed:
    /// whatever wants attention first, else the most recently active.
    private var focusTargetSession: SessionState? {
        sessionMonitor.instances.first { $0.phase.isWaitingForApproval }
            ?? sessionMonitor.instances.first { $0.phase == .processing }
            ?? sessionMonitor.instances.max { $0.lastActivity < $1.lastActivity }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        OpenClaudeBackdrop(
            session: nil,
            rateLimits: sessionMonitor.accountRateLimits,
            onActivate: { viewModel.notchClose() },
            alignment: .center
        ) {
            VStack(spacing: 8) {
                Text("No sessions")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.notchFG.opacity(0.4))

                Text("Run claude in terminal")
                    .font(.system(size: 11))
                    .foregroundColor(.notchFG.opacity(0.25))
            }
        }
    }

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        sessionMonitor.instances.sorted { a, b in
            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }

    private var instancesList: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(sortedInstances) { session in
                        InstanceRow(
                            session: session,
                            onFocus: { focusSession(session) },
                            onChat: { openChat(session) },
                            onArchive: { archiveSession(session) },
                            onApprove: { approveSession(session) },
                            onReject: { rejectSession(session) }
                        )
                        .id(session.stableId)
                    }
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    listContentHeight = height
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Cap the scroll view at its content height so the leftover space
            // goes to the backdrop instead of the list.
            .frame(maxHeight: listContentHeight > 0 ? listContentHeight : .infinity)
            // Required: without a higher priority the VStack splits the panel
            // evenly between these two flexible children, so a list of five or
            // more rows gets squeezed into half the panel.
            .layoutPriority(1)

            // Blank space below the rows — shows the plan usage dials, and a
            // click here brings Claude back. Deliberately a sibling of the list
            // rather than a background, so a click on a row can never reach it.
            OpenClaudeBackdrop(
                session: focusTargetSession,
                rateLimits: sessionMonitor.accountRateLimits,
                onActivate: { viewModel.notchClose() }
            ) { EmptyView() }
        }
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        Task {
            await TerminalFocuser.focus(session: session)
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }
}

// MARK: - Open Claude Backdrop

/// Fills the panel's blank space with the plan usage dials, and reopens Claude
/// when clicked.
///
/// Without usage data there is nothing to draw, so it falls back to the bare
/// hover hint: the gesture would otherwise be invisible, but a permanent label
/// would clutter a panel that is mostly a session list.
private struct OpenClaudeBackdrop<Content: View>: View {
    let session: SessionState?
    let rateLimits: RateLimitInfo?
    /// Runs on tap, ahead of the launch, so the island can collapse out of the
    /// way instead of waiting for Claude to come forward.
    let onActivate: () -> Void
    /// Where the readout sits in the room it is given: pinned to the bottom
    /// under a session list, centred when it is the only thing on screen.
    var alignment: Alignment = .bottom
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 10) {
            content()

            // Always shown. Gating this on having plan-limit data also hid the
            // token heatmap, which comes from the transcripts and has nothing
            // to do with the usage endpoint — so a rate-limited or signed-out
            // fetch blanked the whole footer, tabs included.
            UsageReadoutPager(
                rateLimits: rateLimits,
                isHovering: isHovering,
                onOpenClaude: openClaude
            )
        }
        // Bottom-aligned under a list: the readout reads as the panel's footer.
        // Centring it left the block floating in the middle of however much
        // room the list happened to leave, so its position moved with the
        // session count.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture(perform: openClaude)
    }

    private func openClaude() {
        onActivate()
        Task {
            await ClaudeAppLauncher.shared.openClaude(fallbackSession: session)
        }
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var isHovered = false
    @State private var spinnerPhase = 0

    /// Whether we can identify a window to raise for this session. No longer
    /// requires yabai — see `TerminalFocuser`.
    private var canFocusTerminal: Bool {
        session.pid != nil || session.isInTmux
    }

    private let claudeOrange = TerminalColors.claudeOrange
    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    /// Row heading: the prompt you last sent, falling back to the session's
    /// own title while no prompt has been parsed yet.
    private var headingText: String {
        session.lastUserMessage ?? session.displayTitle
    }

    private var contextHelpText: String {
        guard let pct = session.displayContextWindow?.usedPercentage else { return "Context window" }
        return "Context window: \(Int(pct.rounded()))%"
    }

    /// Whether the second line is reporting live activity rather than a reply.
    private var isShowingActivity: Bool {
        session.phase.isRunningTurn
    }

    /// Second line: live activity while the turn runs, Claude's reply once done.
    ///
    /// Falls back to the phase so the line never goes blank — a tool-only turn
    /// carries no prose, and a fresh session has no reply at all.
    private var secondLineText: String {
        guard isShowingActivity else {
            return session.lastAssistantMessage ?? phaseStatusText
        }

        // Mid-turn the useful thing is the tool in flight.
        if session.lastMessageRole == "tool", let detail = session.lastMessage {
            if let tool = session.lastToolName {
                return "\(MCPToolFormatter.formatToolName(tool)) \(detail)"
            }
            return detail
        }

        // Claude is writing prose, so there is no tool to name. Report the phase
        // rather than the previous reply — a reply that is already on screen looks
        // frozen, which is exactly the "text never updates" complaint.
        return phaseStatusText
    }

    /// Status text based on session phase (fallback when no other content)
    private var phaseStatusText: String {
        switch session.phase {
        case .processing:
            return "Processing..."
        case .compacting:
            return "Compacting..."
        case .waitingForInput:
            return "Ready"
        case .waitingForApproval:
            return "Waiting for approval"
        case .idle:
            return "Idle"
        case .ended:
            return "Ended"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // State indicator on left
            stateIndicator
                .frame(width: 14)

            // Text content
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(headingText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.notchFG)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // Token usage indicator
                    if session.usage.totalTokens > 0 {
                        Text(session.usage.formattedTotal)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.notchFG.opacity(0.3))
                    }
                }

                // Show tool call when waiting for approval, otherwise last activity
                if isWaitingForApproval, let toolName = session.pendingToolName {
                    // Show tool name in amber + input on same line
                    HStack(spacing: 4) {
                        Text(MCPToolFormatter.formatToolName(toolName))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(TerminalColors.amber.opacity(0.9))
                        if isInteractiveTool {
                            Text("Needs your input")
                                .font(.system(size: 11))
                                .foregroundColor(.notchFG.opacity(0.5))
                                .lineLimit(1)
                        } else if let input = session.pendingToolInput {
                            Text(input)
                                .font(.system(size: 11))
                                .foregroundColor(.notchFG.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                } else {
                    // Italic while work is in flight, upright once it's a reply —
                    // the slant is what distinguishes "doing" from "said".
                    Text(secondLineText)
                        .font(.system(size: 11))
                        .italic(isShowingActivity)
                        .foregroundColor(.notchFG.opacity(isShowingActivity ? 0.4 : 0.45))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // Project + branch — what tells two sessions apart when several
                // repos (or worktrees of one repo) are running at once.
                SessionMetaLine(session: session)
            }

            Spacer(minLength: 0)

            // Action icons or approval buttons — the row itself is a single
            // click to chat, so a dedicated chat button here is redundant.
            if isWaitingForApproval && isInteractiveTool {
                // Interactive tools like AskUserQuestion need the terminal to
                // actually answer, so that button stays.
                if canFocusTerminal {
                    TerminalButton(
                        isEnabled: true,
                        onTap: { onFocus() }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            } else if isWaitingForApproval {
                InlineApprovalButtons(
                    onApprove: onApprove,
                    onReject: onReject
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                HStack(spacing: 8) {
                    // This session's context window usage, replacing the old
                    // "raise terminal" eye icon — still reachable via the
                    // crab icon or the chat's own "open desktop" button.
                    UsageLimitRing(
                        percentage: session.displayContextWindow?.usedPercentage,
                        size: 16,
                        lineWidth: 2.5,
                        helpText: contextHelpText,
                        tint: TerminalColors.blue,
                        showsTrack: true
                    )
                    .frame(width: 24, height: 24)

                    // Archive button - only for idle or completed sessions
                    if session.phase == .idle || session.phase == .waitingForInput {
                        IconButton(icon: "archivebox") {
                            onArchive()
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onChat()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.notchFG.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    /// Advance the spinner while this row is busy.
    ///
    /// Previously a per-row 0.15s timer that fired for every row in the list,
    /// idle ones included; now it only runs inside the busy branches below.
    private func runSpinner() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { break }
            spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch session.phase {
        case .processing, .compacting:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(claudeOrange)
                .task { await runSpinner() }
        case .waitingForApproval:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(TerminalColors.amber)
                .task { await runSpinner() }
        case .waitingForInput:
            Circle()
                .fill(TerminalColors.green)
                .frame(width: 6, height: 6)
        case .idle, .ended:
            Circle()
                .fill(Color.notchFG.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var showDenyButton = false
    @State private var showAllowButton = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                onReject()
            } label: {
                Text("Deny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.notchFG.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.notchFG.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.notchFGInverted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.notchFG.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? .notchFG.opacity(0.8) : .notchFG.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.notchFG.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? .notchFG.opacity(0.9) : .notchFG.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.notchFG.opacity(0.15) : Color.notchFG.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isEnabled ? .notchFGInverted : .notchFG.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.notchFG.opacity(0.95) : Color.notchFG.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

//
//  SessionState.swift
//  ClaudeIsland
//
//  Unified state model for a Claude session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation

/// Complete state for a single Claude session
/// This is the single source of truth - all state reads and writes go through SessionStore
struct SessionState: Equatable, Identifiable, Sendable {
    // MARK: - Identity

    let sessionId: String
    let cwd: String
    let projectName: String

    // MARK: - Instance Metadata

    var pid: Int?
    var tty: String?
    var isInTmux: Bool

    /// Checked-out branch for `cwd`, refreshed on each status tick.
    var gitBranch: String?

    /// When the current turn started running, or nil when the session is at rest.
    /// Drives the elapsed-time readout on the collapsed notch.
    var turnStartedAt: Date?

    /// When the last turn finished, for the "2 minutes ago" readout.
    var turnEndedAt: Date?

    // MARK: - State Machine

    /// Current phase in the session lifecycle
    var phase: SessionPhase

    /// Claude Code's current permission mode for this session, as last
    /// reported by a hook event. Nil until the first event carries one.
    var permissionMode: ClaudePermissionMode?

    /// This session's context window usage, as last reported by Claude
    /// Code's statusLine integration. Nil until the first tick arrives.
    var contextWindow: ContextWindowInfo?

    /// Display name of the model in use (e.g. "Opus"), its raw id (e.g.
    /// "claude-opus-5"), and the current reasoning effort level (e.g.
    /// "high") — all from the same statusLine tick as `contextWindow`.
    /// Effort is nil when the model doesn't support it.
    var modelDisplayName: String?
    var modelId: String?
    var effortLevel: String?

    // MARK: - Chat History

    /// All chat items for this session (replaces ChatHistoryManager.histories)
    var chatItems: [ChatHistoryItem]

    // MARK: - Tool Tracking

    /// Unified tool tracker (replaces 6+ dictionaries in ChatHistoryManager)
    var toolTracker: ToolTracker

    // MARK: - Subagent State

    /// State for Task tools and their nested subagent tools
    var subagentState: SubagentState

    // MARK: - Conversation Info (from JSONL parsing)

    var conversationInfo: ConversationInfo

    // MARK: - Clear Reconciliation

    /// When true, the next file update should reconcile chatItems with parser state
    /// This removes pre-/clear items that no longer exist in the JSONL
    var needsClearReconciliation: Bool

    // MARK: - Timestamps

    var lastActivity: Date
    var createdAt: Date

    // MARK: - Identifiable

    var id: String { sessionId }

    // MARK: - Initialization

    nonisolated init(
        sessionId: String,
        cwd: String,
        projectName: String? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        isInTmux: Bool = false,
        gitBranch: String? = nil,
        turnStartedAt: Date? = nil,
        turnEndedAt: Date? = nil,
        phase: SessionPhase = .idle,
        permissionMode: ClaudePermissionMode? = nil,
        contextWindow: ContextWindowInfo? = nil,
        modelDisplayName: String? = nil,
        modelId: String? = nil,
        effortLevel: String? = nil,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessage: nil,
            lastAssistantMessage: nil, lastUserMessageDate: nil
        ),
        needsClearReconciliation: Bool = false,
        lastActivity: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName ?? URL(fileURLWithPath: cwd).lastPathComponent
        self.pid = pid
        self.tty = tty
        self.isInTmux = isInTmux
        self.gitBranch = gitBranch
        self.turnStartedAt = turnStartedAt
        self.turnEndedAt = turnEndedAt
        self.phase = phase
        self.permissionMode = permissionMode
        self.contextWindow = contextWindow
        self.modelDisplayName = modelDisplayName
        self.modelId = modelId
        self.effortLevel = effortLevel
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.needsClearReconciliation = needsClearReconciliation
        self.lastActivity = lastActivity
        self.createdAt = createdAt
    }

    // MARK: - Derived Properties

    /// Whether this session needs user attention
    var needsAttention: Bool {
        phase.needsAttention
    }

    /// The active permission context, if any
    var activePermission: PermissionContext? {
        if case .waitingForApproval(let ctx) = phase {
            return ctx
        }
        return nil
    }

    // MARK: - UI Convenience Properties

    /// Stable identity for SwiftUI (combines PID and sessionId for animation stability)
    var stableId: String {
        if let pid = pid {
            return "\(pid)-\(sessionId)"
        }
        return sessionId
    }

    /// Display title: summary > first user message > project name
    var displayTitle: String {
        conversationInfo.summary ?? conversationInfo.firstUserMessage ?? projectName
    }

    /// Best hint for matching window title
    var windowHint: String {
        conversationInfo.summary ?? projectName
    }

    /// "Opus 5", "Haiku 4.5" — the friendly model name with its version
    /// suffix from the model id, since `modelDisplayName` alone doesn't
    /// carry it (Claude Code reports "Opus" whether it's Opus 4 or 5).
    var modelNameWithVersion: String? {
        guard let modelDisplayName else { return modelId }
        guard let modelId else { return modelDisplayName }

        let tokens = modelId.split(separator: "-").map(String.init)
        let versionTokens = tokens.drop(while: { $0.caseInsensitiveCompare(modelDisplayName) != .orderedSame })
            .dropFirst()
        guard !versionTokens.isEmpty else { return modelDisplayName }
        return "\(modelDisplayName) \(versionTokens.joined(separator: "."))"
    }

    // MARK: - Session Setup Readout
    //
    // The statusLine hook is authoritative but only fires for Claude Code in a
    // terminal — the desktop app has no status line to render, so it never runs
    // that command. These fall back to the transcript, which records the same
    // facts on every assistant turn, so the chat footer fills in either way.

    /// "Opus 5" — the model in use, however we can find out.
    var displayModelName: String? {
        modelNameWithVersion ?? Self.friendlyModelName(conversationInfo.turnContext.modelId)
    }

    /// Reasoning effort ("max", "high"), or nil when the model has none.
    var displayEffortLevel: String? {
        effortLevel ?? conversationInfo.turnContext.effortLevel
    }

    /// Context window usage. A statusLine figure always wins: it is the only
    /// source that *knows* the window size, which the transcript never records.
    var displayContextWindow: ContextWindowInfo? {
        if let contextWindow { return contextWindow }
        guard let tokens = conversationInfo.turnContext.contextTokens else { return nil }

        let size = inferredContextWindowSize(occupying: tokens)
        return ContextWindowInfo(
            usedPercentage: min(Double(tokens) / Double(size) * 100, 100),
            contextWindowSize: size,
            totalInputTokens: tokens,
            totalOutputTokens: nil
        )
    }

    /// Best guess at the window this session runs in, for the transcript-derived
    /// readout only.
    ///
    /// Two signals, no third: usage past the standard size is *proof* of the
    /// extended window, since Claude Code would have compacted long before
    /// otherwise. Short of that, a session with no controlling terminal is
    /// hosted by Claude Desktop, which runs extended — the same `tty == nil`
    /// test `MessageSender` uses to spot a GUI host.
    private func inferredContextWindowSize(occupying tokens: Int) -> Int {
        if tokens > Self.standardContextWindowSize { return Self.extendedContextWindowSize }
        return tty == nil ? Self.extendedContextWindowSize : Self.standardContextWindowSize
    }

    private static let standardContextWindowSize = 200_000
    private static let extendedContextWindowSize = 1_000_000

    /// "claude-opus-5" -> "Opus 5", "claude-haiku-4-5-20251001" -> "Haiku 4.5".
    ///
    /// Picks the family out by name rather than by position, because model ids
    /// put the version on either side of it: "claude-opus-5" but also
    /// "claude-3-5-sonnet-20241022".
    private static func friendlyModelName(_ modelId: String?) -> String? {
        guard let modelId, !modelId.isEmpty else { return nil }

        var tokens = modelId.split(separator: "-").map(String.init)
        if tokens.first?.caseInsensitiveCompare("claude") == .orderedSame {
            tokens.removeFirst()
        }

        let isNumeric = { (token: String) in !token.isEmpty && token.allSatisfy(\.isNumber) }
        guard let family = tokens.first(where: { !isNumeric($0) }) else { return modelId }

        // Version parts are the numeric tokens; an 8-digit one is a release date
        // rather than a version, and belongs in neither.
        let versionTokens = tokens.filter { isNumeric($0) && $0.count < 8 }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        guard !versionTokens.isEmpty else { return name }
        return "\(name) \(versionTokens.joined(separator: "."))"
    }

    /// Pending tool name if waiting for approval
    var pendingToolName: String? {
        activePermission?.toolName
    }

    /// Pending tool use ID
    var pendingToolId: String? {
        activePermission?.toolUseId
    }

    /// Formatted pending tool input for display
    var pendingToolInput: String? {
        activePermission?.formattedInput
    }

    /// Last message content
    var lastMessage: String? {
        conversationInfo.lastMessage
    }

    /// Last message role
    var lastMessageRole: String? {
        conversationInfo.lastMessageRole
    }

    /// Last tool name
    var lastToolName: String? {
        conversationInfo.lastToolName
    }

    /// Summary
    var summary: String? {
        conversationInfo.summary
    }

    /// First user message
    var firstUserMessage: String? {
        conversationInfo.firstUserMessage
    }

    /// Text of the most recent message the user sent
    var lastUserMessage: String? {
        conversationInfo.lastUserMessage
    }

    /// Text of Claude's most recent reply
    var lastAssistantMessage: String? {
        conversationInfo.lastAssistantMessage
    }

    /// Last user message date
    var lastUserMessageDate: Date? {
        conversationInfo.lastUserMessageDate
    }

    /// Token usage for this session
    var usage: UsageInfo {
        conversationInfo.usage
    }

    /// Whether the session can be interacted with
    var canInteract: Bool {
        phase.needsAttention
    }
}

// MARK: - Tool Tracker

/// Unified tool tracking - replaces multiple dictionaries in ChatHistoryManager
struct ToolTracker: Equatable, Sendable {
    /// Tools currently in progress, keyed by tool_use_id
    var inProgress: [String: ToolInProgress]

    /// All tool IDs we've seen (for deduplication)
    var seenIds: Set<String>

    /// Last JSONL file offset for incremental parsing
    var lastSyncOffset: UInt64

    /// Last sync timestamp
    var lastSyncTime: Date?

    nonisolated init(
        inProgress: [String: ToolInProgress] = [:],
        seenIds: Set<String> = [],
        lastSyncOffset: UInt64 = 0,
        lastSyncTime: Date? = nil
    ) {
        self.inProgress = inProgress
        self.seenIds = seenIds
        self.lastSyncOffset = lastSyncOffset
        self.lastSyncTime = lastSyncTime
    }

    /// Mark a tool ID as seen, returns true if it was new
    nonisolated mutating func markSeen(_ id: String) -> Bool {
        seenIds.insert(id).inserted
    }

    /// Check if a tool ID has been seen
    nonisolated func hasSeen(_ id: String) -> Bool {
        seenIds.contains(id)
    }

    /// Start tracking a tool
    nonisolated mutating func startTool(id: String, name: String) {
        guard markSeen(id) else { return }
        inProgress[id] = ToolInProgress(
            id: id,
            name: name,
            startTime: Date(),
            phase: .running
        )
    }

    /// Complete a tool
    nonisolated mutating func completeTool(id: String, success: Bool) {
        inProgress.removeValue(forKey: id)
    }
}

/// A tool currently in progress
struct ToolInProgress: Equatable, Sendable {
    let id: String
    let name: String
    let startTime: Date
    var phase: ToolInProgressPhase
}

/// Phase of a tool in progress
enum ToolInProgressPhase: Equatable, Sendable {
    case starting
    case running
    case pendingApproval
}

// MARK: - Subagent State

/// State for Task (subagent) tools
struct SubagentState: Equatable, Sendable {
    /// Active Task tools, keyed by task tool_use_id
    var activeTasks: [String: TaskContext]

    /// Ordered stack of active task IDs (most recent last) - used for proper tool assignment
    /// When multiple Tasks run in parallel, we use insertion order rather than timestamps
    var taskStack: [String]

    /// Mapping of agentId to Task description (for AgentOutputTool display)
    var agentDescriptions: [String: String]

    nonisolated init(activeTasks: [String: TaskContext] = [:], taskStack: [String] = [], agentDescriptions: [String: String] = [:]) {
        self.activeTasks = activeTasks
        self.taskStack = taskStack
        self.agentDescriptions = agentDescriptions
    }

    /// Whether there's an active subagent
    nonisolated var hasActiveSubagent: Bool {
        !activeTasks.isEmpty
    }

    /// Start tracking a Task tool
    nonisolated mutating func startTask(taskToolId: String, description: String? = nil) {
        activeTasks[taskToolId] = TaskContext(
            taskToolId: taskToolId,
            startTime: Date(),
            agentId: nil,
            description: description,
            subagentTools: []
        )
    }

    /// Stop tracking a Task tool
    nonisolated mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    /// Set the agentId for a Task (called when agent file is discovered)
    nonisolated mutating func setAgentId(_ agentId: String, for taskToolId: String) {
        activeTasks[taskToolId]?.agentId = agentId
        if let description = activeTasks[taskToolId]?.description {
            agentDescriptions[agentId] = description
        }
    }

    /// Add a subagent tool to a specific Task by ID
    nonisolated mutating func addSubagentToolToTask(_ tool: SubagentToolCall, taskId: String) {
        activeTasks[taskId]?.subagentTools.append(tool)
    }

    /// Set all subagent tools for a specific Task (used when updating from agent file)
    nonisolated mutating func setSubagentTools(_ tools: [SubagentToolCall], for taskId: String) {
        activeTasks[taskId]?.subagentTools = tools
    }

    /// Add a subagent tool to the most recent active Task
    nonisolated mutating func addSubagentTool(_ tool: SubagentToolCall) {
        // Find most recent active task (for parallel Task support)
        guard let mostRecentTaskId = activeTasks.keys.max(by: {
            (activeTasks[$0]?.startTime ?? .distantPast) < (activeTasks[$1]?.startTime ?? .distantPast)
        }) else { return }

        activeTasks[mostRecentTaskId]?.subagentTools.append(tool)
    }

    /// Update the status of a subagent tool across all active Tasks
    nonisolated mutating func updateSubagentToolStatus(toolId: String, status: ToolStatus) {
        for taskId in activeTasks.keys {
            if let index = activeTasks[taskId]?.subagentTools.firstIndex(where: { $0.id == toolId }) {
                activeTasks[taskId]?.subagentTools[index].status = status
                return
            }
        }
    }
}

/// Context for an active Task tool
struct TaskContext: Equatable, Sendable {
    let taskToolId: String
    let startTime: Date
    var agentId: String?
    var description: String?
    var subagentTools: [SubagentToolCall]
}

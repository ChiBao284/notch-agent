//
//  ConversationParser.swift
//  ClaudeIsland
//
//  Parses Claude JSONL conversation files to extract summary and last message
//  Optimized for incremental parsing - only reads new lines since last sync
//

import Foundation
import os.log

/// Token usage information from a session
struct UsageInfo: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0

    var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// Formatted string for display (e.g., "12.5K tokens")
    var formattedTotal: String {
        Self.formattedCount(totalTokens)
    }

    private static func formattedCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }
}

/// What the newest assistant turn says about the session's setup.
///
/// The statusLine hook reports the same things, but only Claude Code running in
/// a terminal ever invokes it — under Claude Code Desktop these fields are the
/// only source, so the chat footer would otherwise stay blank.
struct TurnContext: Equatable {
    /// Model id as the transcript records it, e.g. "claude-opus-5".
    var modelId: String?
    /// Reasoning effort for the turn, e.g. "max".
    var effortLevel: String?
    /// Tokens occupying the context window on the newest turn: fresh input plus
    /// both halves of the cache. Not a running total — the latest turn's figure
    /// *is* the current occupancy.
    var contextTokens: Int?
}

struct ConversationInfo: Equatable {
    let summary: String?
    let lastMessage: String?
    let lastMessageRole: String?  // "user", "assistant", or "tool"
    let lastToolName: String?  // Tool name if lastMessageRole is "tool"
    let firstUserMessage: String?  // Fallback title when no summary
    let lastUserMessage: String?  // Text of the last message the user sent
    let lastAssistantMessage: String?  // Text of Claude's most recent reply
    let lastUserMessageDate: Date?  // Timestamp of last user message (for stable sorting)
    var usage: UsageInfo = UsageInfo()  // Token usage stats
    var turnContext: TurnContext = TurnContext()  // Model / effort / context occupancy
}

actor ConversationParser {
    static let shared = ConversationParser()

    /// Logger for conversation parser (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "Parser")

    /// Shared ISO8601 date formatter (expensive to create, reused across all message parsing)
    nonisolated private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Cache of parsed conversation info, keyed by session file path
    private var cache: [String: CachedInfo] = [:]

    private var incrementalState: [String: IncrementalParseState] = [:]

    private struct CachedInfo {
        let modificationDate: Date
        /// Byte offset just past the last newline we have folded in. A trailing
        /// partial line is deliberately left unconsumed and re-read next time.
        let parsedBytes: UInt64
        let info: ConversationInfo
    }

    /// State for incremental JSONL parsing
    private struct IncrementalParseState {
        var lastFileOffset: UInt64 = 0
        var messages: [ChatMessage] = []
        var seenToolIds: Set<String> = []
        var toolIdToName: [String: String] = [:]  // Map tool_use_id to tool name
        var completedToolIds: Set<String> = []  // Tools that have received results
        var toolResults: [String: ToolResult] = [:]  // Tool results keyed by tool_use_id
        var structuredResults: [String: ToolResultData] = [:]  // Structured results keyed by tool_use_id
        var lastClearOffset: UInt64 = 0  // Offset of last /clear command (0 = none or at start)
        var clearPending: Bool = false  // True if a /clear was just detected
    }

    /// Parsed tool result data
    struct ToolResult {
        let content: String?
        let stdout: String?
        let stderr: String?
        let isError: Bool
        let isInterrupted: Bool

        init(content: String?, stdout: String?, stderr: String?, isError: Bool) {
            self.content = content
            self.stdout = stdout
            self.stderr = stderr
            self.isError = isError
            // Detect if this was an interrupt or rejection (various formats)
            self.isInterrupted = isError && (
                content?.contains("Interrupted by user") == true ||
                content?.contains("interrupted by user") == true ||
                content?.contains("user doesn't want to proceed") == true
            )
        }
    }

    /// Parse a JSONL file to extract conversation info
    /// Uses caching based on file modification time
    func parse(sessionId: String, cwd: String) -> ConversationInfo {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let sessionFile = ClaudePaths.projectsDir.path + "/" + projectDir + "/" + sessionId + ".jsonl"

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionFile),
              let attrs = try? fileManager.attributesOfItem(atPath: sessionFile),
              let modDate = attrs[.modificationDate] as? Date else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessage: nil, lastAssistantMessage: nil, lastUserMessageDate: nil)
        }

        if let cached = cache[sessionFile], cached.modificationDate == modDate {
            return cached.info
        }

        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        // Fast path: the log only ever gets appended to during a session, so fold
        // in the new bytes instead of re-reading the whole file. That file reaches
        // tens of MB over a long session and this runs on every hook-driven sync,
        // so a full re-parse made cost grow with conversation length.
        if let cached = cache[sessionFile],
           cached.parsedBytes > 0,
           fileSize > cached.parsedBytes,
           let (appended, consumedTo) = readAppended(path: sessionFile, from: cached.parsedBytes) {
            let delta = scan(lines: appended)
            let merged = merge(cached.info, with: delta)
            cache[sessionFile] = CachedInfo(modificationDate: modDate, parsedBytes: consumedTo, info: merged)
            return merged
        }

        // Slow path: first sight of the file, or it was rewritten/truncated
        // (a /clear does that), so nothing cached can be trusted.
        guard let data = fileManager.contents(atPath: sessionFile),
              let content = String(data: data, encoding: .utf8) else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessage: nil, lastAssistantMessage: nil, lastUserMessageDate: nil)
        }

        let info = parseContent(content)
        cache[sessionFile] = CachedInfo(
            modificationDate: modDate,
            parsedBytes: Self.completeLineBoundary(of: data),
            info: info
        )

        return info
    }

    // MARK: - Incremental Folding

    /// Read the bytes appended since `offset`, returning whole lines only plus
    /// the offset just past the last newline consumed.
    private func readAppended(path: String, from offset: UInt64) -> ([String], UInt64)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }

        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // Ignore a trailing partial line; it will be complete on the next pass.
        let boundary = Self.completeLineBoundary(of: data)
        guard boundary > 0 else { return nil }

        let whole = data.prefix(Int(boundary))
        guard let text = String(data: whole, encoding: .utf8) else { return nil }

        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        return (lines, offset + boundary)
    }

    /// Byte count of `data` up to and including its final newline.
    private nonisolated static func completeLineBoundary(of data: Data) -> UInt64 {
        guard let index = data.lastIndex(of: 0x0A) else { return 0 }
        return UInt64(data.distance(from: data.startIndex, to: index) + 1)
    }

    /// Fold a freshly scanned slice into the running result.
    ///
    /// Every field's semantics survive this: the "last X" fields take the newest
    /// occurrence, so a hit in the new slice wins and a miss keeps the old value;
    /// `firstUserMessage` is the oldest occurrence so the cached one always wins;
    /// usage is a running total so the slice's tokens are added; `turnContext`
    /// describes the newest turn, so each field takes the slice's value when the
    /// slice had one.
    private func merge(_ base: ConversationInfo, with delta: ContentDelta) -> ConversationInfo {
        var usage = base.usage
        usage.inputTokens += delta.usage.inputTokens
        usage.outputTokens += delta.usage.outputTokens
        usage.cacheReadTokens += delta.usage.cacheReadTokens
        usage.cacheCreationTokens += delta.usage.cacheCreationTokens

        let turnContext = TurnContext(
            modelId: delta.turnContext.modelId ?? base.turnContext.modelId,
            effortLevel: delta.turnContext.effortLevel ?? base.turnContext.effortLevel,
            contextTokens: delta.turnContext.contextTokens ?? base.turnContext.contextTokens
        )

        return ConversationInfo(
            summary: delta.summary ?? base.summary,
            lastMessage: delta.lastMessage.map { Self.truncateMessage($0, maxLength: 80) ?? $0 } ?? base.lastMessage,
            lastMessageRole: delta.lastMessage != nil ? delta.lastMessageRole : base.lastMessageRole,
            lastToolName: delta.lastMessage != nil ? delta.lastToolName : base.lastToolName,
            firstUserMessage: base.firstUserMessage ?? delta.firstUserMessage.map { Self.truncateMessage($0, maxLength: 50) ?? $0 },
            lastUserMessage: delta.lastUserMessage.map { Self.truncateMessage($0, maxLength: 80) ?? $0 } ?? base.lastUserMessage,
            lastAssistantMessage: delta.lastAssistantMessage.map { Self.truncateMessage($0, maxLength: 90) ?? $0 } ?? base.lastAssistantMessage,
            lastUserMessageDate: delta.lastUserMessageDate ?? base.lastUserMessageDate,
            usage: usage,
            turnContext: turnContext
        )
    }

    /// Fields harvested from one slice of the log, before truncation.
    private struct ContentDelta {
        var summary: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var firstUserMessage: String?
        var lastUserMessage: String?
        var lastAssistantMessage: String?
        var lastUserMessageDate: Date?
        var usage = UsageInfo()
        var turnContext = TurnContext()
    }

    /// Parse JSONL content
    private func parseContent(_ content: String) -> ConversationInfo {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let delta = scan(lines: lines)

        return ConversationInfo(
            summary: delta.summary,
            lastMessage: Self.truncateMessage(delta.lastMessage, maxLength: 80),
            lastMessageRole: delta.lastMessageRole,
            lastToolName: delta.lastToolName,
            firstUserMessage: Self.truncateMessage(delta.firstUserMessage, maxLength: 50),
            lastUserMessage: Self.truncateMessage(delta.lastUserMessage, maxLength: 80),
            lastAssistantMessage: Self.truncateMessage(delta.lastAssistantMessage, maxLength: 90),
            lastUserMessageDate: delta.lastUserMessageDate,
            usage: delta.usage,
            turnContext: delta.turnContext
        )
    }

    /// Harvest every field of interest from a slice of log lines.
    ///
    /// Decodes each line exactly once. The previous version ran three separate
    /// loops that each re-ran `JSONSerialization` over the same lines, so a file
    /// of N lines cost up to 2N decodes.
    private func scan(lines: [String]) -> ContentDelta {
        var delta = ContentDelta()
        let formatter = Self.isoFormatter

        // Decode once, keeping only what later passes need.
        var decoded: [[String: Any]] = []
        decoded.reserveCapacity(lines.count)

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            decoded.append(json)

            // Usage is a running total over every assistant turn.
            if json["type"] as? String == "assistant",
               let message = json["message"] as? [String: Any] {
                if let usageDict = message["usage"] as? [String: Any] {
                    let input = usageDict["input_tokens"] as? Int ?? 0
                    let cacheRead = usageDict["cache_read_input_tokens"] as? Int ?? 0
                    let cacheCreation = usageDict["cache_creation_input_tokens"] as? Int ?? 0

                    delta.usage.inputTokens += input
                    delta.usage.outputTokens += usageDict["output_tokens"] as? Int ?? 0
                    delta.usage.cacheReadTokens += cacheRead
                    delta.usage.cacheCreationTokens += cacheCreation

                    // Context occupancy, unlike the totals above, is whatever
                    // the newest turn reports — so assign rather than add.
                    delta.turnContext.contextTokens = input + cacheRead + cacheCreation
                }

                // `effort` sits on the envelope, `model` inside the message.
                delta.turnContext.modelId = message["model"] as? String ?? delta.turnContext.modelId
                delta.turnContext.effortLevel = json["effort"] as? String ?? delta.turnContext.effortLevel
            }
        }

        // Oldest real user prompt, for the fallback title.
        for json in decoded {
            guard json["type"] as? String == "user", !(json["isMeta"] as? Bool ?? false) else { continue }
            guard let message = json["message"] as? [String: Any],
                  let msgContent = message["content"] as? String,
                  !msgContent.hasPrefix("<command-name>"),
                  !msgContent.hasPrefix("<local-command"),
                  !msgContent.hasPrefix("Caveat:") else { continue }
            delta.firstUserMessage = msgContent
            break
        }

        // Newest of everything else.
        var foundLastUserMessage = false
        var foundLastAssistantMessage = false

        for json in decoded.reversed() {
            let type = json["type"] as? String

            if delta.lastMessage == nil, type == "user" || type == "assistant" {
                let isMeta = json["isMeta"] as? Bool ?? false
                if !isMeta, let message = json["message"] as? [String: Any] {
                    if let msgContent = message["content"] as? String {
                        if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                            delta.lastMessage = msgContent
                            delta.lastMessageRole = type
                        }
                    } else if let contentArray = message["content"] as? [[String: Any]] {
                        for block in contentArray.reversed() {
                            let blockType = block["type"] as? String
                            if blockType == "tool_use" {
                                let toolName = block["name"] as? String ?? "Tool"
                                delta.lastMessage = Self.formatToolInput(block["input"] as? [String: Any], toolName: toolName)
                                delta.lastMessageRole = "tool"
                                delta.lastToolName = toolName
                                break
                            } else if blockType == "text", let text = block["text"] as? String {
                                if !text.hasPrefix("[Request interrupted by user") {
                                    delta.lastMessage = text
                                    delta.lastMessageRole = type
                                    break
                                }
                            }
                        }
                    }
                }
            }

            if !foundLastUserMessage, type == "user", !(json["isMeta"] as? Bool ?? false),
               let message = json["message"] as? [String: Any],
               let text = Self.userTypedText(from: message["content"]) {
                delta.lastUserMessage = text
                if let timestampStr = json["timestamp"] as? String {
                    delta.lastUserMessageDate = formatter.date(from: timestampStr)
                }
                foundLastUserMessage = true
            }

            if !foundLastAssistantMessage, type == "assistant",
               let message = json["message"] as? [String: Any],
               let text = Self.assistantText(from: message["content"]) {
                delta.lastAssistantMessage = text
                foundLastAssistantMessage = true
            }

            if delta.summary == nil, type == "summary", let summaryText = json["summary"] as? String {
                delta.summary = summaryText
            }

            if delta.summary != nil && delta.lastMessage != nil && foundLastUserMessage && foundLastAssistantMessage {
                break
            }
        }

        return delta
    }

    /// Format tool input for display in instance list
    private static func formatToolInput(_ input: [String: Any]?, toolName: String) -> String {
        guard let input = input else { return "" }

        switch toolName {
        case "Read", "Write", "Edit":
            if let filePath = input["file_path"] as? String {
                return (filePath as NSString).lastPathComponent
            }
        case "Bash":
            // The description is written for humans; the raw command is noise
            // in a one-line status.
            if let description = input["description"] as? String, !description.isEmpty {
                return description
            }
            if let command = input["command"] as? String {
                return command
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Task", "Agent":
            // "Task" is the legacy name; Claude Code now uses "Agent"
            if let description = input["description"] as? String {
                return description
            }
        case "WebFetch":
            if let url = input["url"] as? String {
                return url
            }
        case "WebSearch":
            if let query = input["query"] as? String {
                return query
            }
        default:
            for (_, value) in input {
                if let str = value as? String, !str.isEmpty {
                    return str
                }
            }
        }
        return ""
    }

    /// Truncate message for display
    /// Text of a message the user actually typed, or nil if this is not one.
    ///
    /// Skips slash-command envelopes, the session Caveat preamble, and
    /// `tool_result` payloads — those arrive as `type: "user"` too but are the
    /// harness talking, not the person.
    private static func userTypedText(from content: Any?) -> String? {
        if let text = content as? String {
            guard !text.hasPrefix("<command-name>"),
                  !text.hasPrefix("<local-command"),
                  !text.hasPrefix("Caveat:") else { return nil }
            return text
        }

        guard let blocks = content as? [[String: Any]] else { return nil }
        // A turn carrying a tool result is the harness replying, never the user.
        guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }

        for block in blocks where block["type"] as? String == "text" {
            guard let text = block["text"] as? String,
                  !text.hasPrefix("<command-name>"),
                  !text.hasPrefix("<local-command"),
                  !text.hasPrefix("Caveat:") else { continue }
            return text
        }
        return nil
    }

    /// Claude's prose from an assistant turn, or nil for a tool-only turn.
    ///
    /// A turn that just calls tools carries no text block, and the interrupt
    /// marker is bookkeeping rather than something Claude said.
    private static func assistantText(from content: Any?) -> String? {
        if let text = content as? String {
            return text.hasPrefix("[Request interrupted by user") ? nil : text
        }

        guard let blocks = content as? [[String: Any]] else { return nil }

        for block in blocks.reversed() where block["type"] as? String == "text" {
            guard let text = block["text"] as? String,
                  !text.hasPrefix("[Request interrupted by user"),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return text
        }
        return nil
    }

    private static func truncateMessage(_ message: String?, maxLength: Int = 80) -> String? {
        guard let msg = message else { return nil }
        let cleaned = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }

    // MARK: - Full Conversation Parsing

    /// Parse full conversation history for chat view (returns ALL messages - use sparingly)
    func parseFullConversation(sessionId: String, cwd: String) -> [ChatMessage] {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return []
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        _ = parseNewLines(filePath: sessionFile, state: &state)
        incrementalState[sessionId] = state

        return state.messages
    }

    /// Result of incremental parsing
    struct IncrementalParseResult {
        let newMessages: [ChatMessage]
        let allMessages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
        let clearDetected: Bool
    }

    /// Parse only NEW messages since last call (efficient incremental updates)
    func parseIncremental(sessionId: String, cwd: String) -> IncrementalParseResult {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return IncrementalParseResult(
                newMessages: [],
                allMessages: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                clearDetected: false
            )
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        let newMessages = parseNewLines(filePath: sessionFile, state: &state)
        let clearDetected = state.clearPending
        if clearDetected {
            state.clearPending = false
        }
        incrementalState[sessionId] = state

        return IncrementalParseResult(
            newMessages: newMessages,
            allMessages: state.messages,
            completedToolIds: state.completedToolIds,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            clearDetected: clearDetected
        )
    }

    /// Parse only new lines since last read (incremental)
    private func parseNewLines(filePath: String, state: inout IncrementalParseState) -> [ChatMessage] {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            return []
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return []
        }

        if fileSize < state.lastFileOffset {
            state = IncrementalParseState()
        }

        if fileSize == state.lastFileOffset {
            return state.messages
        }

        do {
            try fileHandle.seek(toOffset: state.lastFileOffset)
        } catch {
            return state.messages
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return state.messages
        }

        state.clearPending = false
        let isIncrementalRead = state.lastFileOffset > 0
        let lines = newContent.components(separatedBy: "\n")
        var newMessages: [ChatMessage] = []

        for line in lines where !line.isEmpty {
            if line.contains("<command-name>/clear</command-name>") {
                state.messages = []
                state.seenToolIds = []
                state.toolIdToName = [:]
                state.completedToolIds = []
                state.toolResults = [:]
                state.structuredResults = [:]

                if isIncrementalRead {
                    state.clearPending = true
                    state.lastClearOffset = state.lastFileOffset
                    Self.logger.debug("/clear detected (new), will notify UI")
                }
                continue
            }

            if line.contains("\"tool_result\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let messageDict = json["message"] as? [String: Any],
                   let contentArray = messageDict["content"] as? [[String: Any]] {
                    let toolUseResult = json["toolUseResult"] as? [String: Any]
                    let topLevelToolName = json["toolName"] as? String
                    let stdout = toolUseResult?["stdout"] as? String
                    let stderr = toolUseResult?["stderr"] as? String

                    for block in contentArray {
                        if block["type"] as? String == "tool_result",
                           let toolUseId = block["tool_use_id"] as? String {
                            state.completedToolIds.insert(toolUseId)

                            let content = block["content"] as? String
                            let isError = block["is_error"] as? Bool ?? false
                            state.toolResults[toolUseId] = ToolResult(
                                content: content,
                                stdout: stdout,
                                stderr: stderr,
                                isError: isError
                            )

                            let toolName = topLevelToolName ?? state.toolIdToName[toolUseId]

                            if let toolUseResult = toolUseResult,
                               let name = toolName {
                                let structured = Self.parseStructuredResult(
                                    toolName: name,
                                    toolUseResult: toolUseResult,
                                    isError: isError
                                )
                                state.structuredResults[toolUseId] = structured
                            }
                        }
                    }
                }
            } else if line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let message = parseMessageLine(json, seenToolIds: &state.seenToolIds, toolIdToName: &state.toolIdToName) {
                    newMessages.append(message)
                    state.messages.append(message)
                }
            }
        }

        state.lastFileOffset = fileSize
        return newMessages
    }

    /// Get set of completed tool IDs for a session
    func completedToolIds(for sessionId: String) -> Set<String> {
        return incrementalState[sessionId]?.completedToolIds ?? []
    }

    /// Get tool results for a session
    func toolResults(for sessionId: String) -> [String: ToolResult] {
        return incrementalState[sessionId]?.toolResults ?? [:]
    }

    /// Get structured tool results for a session
    func structuredResults(for sessionId: String) -> [String: ToolResultData] {
        return incrementalState[sessionId]?.structuredResults ?? [:]
    }

    /// Reset incremental state for a session (call when reloading)
    func resetState(for sessionId: String) {
        incrementalState.removeValue(forKey: sessionId)
    }

    /// Check if a /clear command was detected during the last parse
    /// Returns true once and consumes the pending flag
    func checkAndConsumeClearDetected(for sessionId: String) -> Bool {
        guard var state = incrementalState[sessionId], state.clearPending else {
            return false
        }
        state.clearPending = false
        incrementalState[sessionId] = state
        return true
    }

    /// Build session file path
    private static func sessionFilePath(sessionId: String, cwd: String) -> String {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return ClaudePaths.projectsDir.path + "/" + projectDir + "/" + sessionId + ".jsonl"
    }

    /// Build subagent JSONL file path.
    ///
    /// Current Claude Code nests subagent files under the parent session:
    ///   projects/<project>/<sessionId>/subagents/agent-<agentId>.jsonl
    ///
    /// Older Claude Code versions stored them flat:
    ///   projects/<project>/agent-<agentId>.jsonl
    ///
    /// Prefer the nested path; fall back to the flat path if only it exists
    /// (cross-version compatibility). If neither exists yet (file still being
    /// created) we return the nested path as the modern default.
    nonisolated static func subagentFilePath(sessionId: String, agentId: String, projectDir: String) -> String {
        let base = ClaudePaths.projectsDir.path + "/" + projectDir
        let nested = base + "/" + sessionId + "/subagents/agent-" + agentId + ".jsonl"
        let flat = base + "/agent-" + agentId + ".jsonl"

        let fm = FileManager.default
        if fm.fileExists(atPath: nested) { return nested }
        if fm.fileExists(atPath: flat) { return flat }
        return nested
    }

    private func parseMessageLine(_ json: [String: Any], seenToolIds: inout Set<String>, toolIdToName: inout [String: String]) -> ChatMessage? {
        guard let type = json["type"] as? String,
              let uuid = json["uuid"] as? String else {
            return nil
        }

        guard type == "user" || type == "assistant" else {
            return nil
        }

        if json["isMeta"] as? Bool == true {
            return nil
        }

        guard let messageDict = json["message"] as? [String: Any] else {
            return nil
        }

        let timestamp: Date
        if let timestampStr = json["timestamp"] as? String {
            timestamp = Self.isoFormatter.date(from: timestampStr) ?? Date()
        } else {
            timestamp = Date()
        }

        var blocks: [MessageBlock] = []

        if let content = messageDict["content"] as? String {
            if content.hasPrefix("<command-name>") || content.hasPrefix("<local-command") || content.hasPrefix("Caveat:") {
                return nil
            }
            if content.hasPrefix("[Request interrupted by user") {
                blocks.append(.interrupted)
            } else {
                blocks.append(.text(content))
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                if let blockType = block["type"] as? String {
                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String {
                            if text.hasPrefix("[Request interrupted by user") {
                                blocks.append(.interrupted)
                            } else {
                                blocks.append(.text(text))
                            }
                        }
                    case "tool_use":
                        if let toolId = block["id"] as? String {
                            if seenToolIds.contains(toolId) {
                                continue
                            }
                            seenToolIds.insert(toolId)
                            if let toolName = block["name"] as? String {
                                toolIdToName[toolId] = toolName
                            }
                        }
                        if let toolBlock = parseToolUse(block) {
                            blocks.append(.toolUse(toolBlock))
                        }
                    case "thinking":
                        if let thinking = block["thinking"] as? String {
                            blocks.append(.thinking(thinking))
                        }
                    case "image":
                        // Claude Code stores inline images as base64 with media_type.
                        if let source = block["source"] as? [String: Any],
                           let mediaType = source["media_type"] as? String,
                           let data = source["data"] as? String {
                            blocks.append(.image(ImageBlock(mediaType: mediaType, base64Data: data)))
                        }
                    default:
                        break
                    }
                }
            }
        }

        guard !blocks.isEmpty else { return nil }

        let role: ChatRole = type == "user" ? .user : .assistant

        return ChatMessage(
            id: uuid,
            role: role,
            timestamp: timestamp,
            content: blocks
        )
    }

    private func parseToolUse(_ block: [String: Any]) -> ToolUseBlock? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String else {
            return nil
        }

        var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                if let strValue = value as? String {
                    input[key] = strValue
                } else if let intValue = value as? Int {
                    input[key] = String(intValue)
                } else if let boolValue = value as? Bool {
                    input[key] = boolValue ? "true" : "false"
                }
            }
        }

        return ToolUseBlock(id: id, name: name, input: input)
    }

    // MARK: - Structured Result Parsing

    /// Parse tool result JSON into structured ToolResultData
    private static func parseStructuredResult(
        toolName: String,
        toolUseResult: [String: Any],
        isError: Bool
    ) -> ToolResultData {
        if toolName.hasPrefix("mcp__") {
            let parts = String(toolName.dropFirst(5)).components(separatedBy: "__")
            let serverName = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let mcpToolName = parts.dropFirst().joined(separator: "__")
            return .mcp(MCPResult(
                serverName: serverName,
                toolName: mcpToolName.isEmpty ? toolName : mcpToolName,
                rawResult: toolUseResult
            ))
        }

        switch toolName {
        case "Read":
            return parseReadResult(toolUseResult)
        case "Edit":
            return parseEditResult(toolUseResult)
        case "Write":
            return parseWriteResult(toolUseResult)
        case "Bash":
            return parseBashResult(toolUseResult)
        case "Grep":
            return parseGrepResult(toolUseResult)
        case "Glob":
            return parseGlobResult(toolUseResult)
        case "TodoWrite":
            return parseTodoWriteResult(toolUseResult)
        case "Task", "Agent":
            return parseTaskResult(toolUseResult)
        case "WebFetch":
            return parseWebFetchResult(toolUseResult)
        case "WebSearch":
            return parseWebSearchResult(toolUseResult)
        case "AskUserQuestion":
            return parseAskUserQuestionResult(toolUseResult)
        case "BashOutput":
            return parseBashOutputResult(toolUseResult)
        case "KillShell":
            return parseKillShellResult(toolUseResult)
        case "ExitPlanMode":
            return parseExitPlanModeResult(toolUseResult)
        default:
            let content = toolUseResult["content"] as? String ??
                          toolUseResult["stdout"] as? String ??
                          toolUseResult["result"] as? String
            return .generic(GenericResult(rawContent: content, rawData: toolUseResult))
        }
    }

    // MARK: - Individual Tool Result Parsers

    private static func parseReadResult(_ data: [String: Any]) -> ToolResultData {
        if let fileData = data["file"] as? [String: Any] {
            return .read(ReadResult(
                filePath: fileData["filePath"] as? String ?? "",
                content: fileData["content"] as? String ?? "",
                numLines: fileData["numLines"] as? Int ?? 0,
                startLine: fileData["startLine"] as? Int ?? 1,
                totalLines: fileData["totalLines"] as? Int ?? 0
            ))
        }
        return .read(ReadResult(
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            numLines: data["numLines"] as? Int ?? 0,
            startLine: data["startLine"] as? Int ?? 1,
            totalLines: data["totalLines"] as? Int ?? 0
        ))
    }

    private static func parseEditResult(_ data: [String: Any]) -> ToolResultData {
        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .edit(EditResult(
            filePath: data["filePath"] as? String ?? "",
            oldString: data["oldString"] as? String ?? "",
            newString: data["newString"] as? String ?? "",
            replaceAll: data["replaceAll"] as? Bool ?? false,
            userModified: data["userModified"] as? Bool ?? false,
            structuredPatch: patches
        ))
    }

    private static func parseWriteResult(_ data: [String: Any]) -> ToolResultData {
        let typeStr = data["type"] as? String ?? "create"
        let writeType: WriteResult.WriteType = typeStr == "overwrite" ? .overwrite : .create

        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .write(WriteResult(
            type: writeType,
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            structuredPatch: patches
        ))
    }

    private static func parseBashResult(_ data: [String: Any]) -> ToolResultData {
        return .bash(BashResult(
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            interrupted: data["interrupted"] as? Bool ?? false,
            isImage: data["isImage"] as? Bool ?? false,
            returnCodeInterpretation: data["returnCodeInterpretation"] as? String,
            backgroundTaskId: data["backgroundTaskId"] as? String
        ))
    }

    private static func parseGrepResult(_ data: [String: Any]) -> ToolResultData {
        let modeStr = data["mode"] as? String ?? "files_with_matches"
        let mode: GrepResult.Mode
        switch modeStr {
        case "content": mode = .content
        case "count": mode = .count
        default: mode = .filesWithMatches
        }

        return .grep(GrepResult(
            mode: mode,
            filenames: data["filenames"] as? [String] ?? [],
            numFiles: data["numFiles"] as? Int ?? 0,
            content: data["content"] as? String,
            numLines: data["numLines"] as? Int,
            appliedLimit: data["appliedLimit"] as? Int
        ))
    }

    private static func parseGlobResult(_ data: [String: Any]) -> ToolResultData {
        return .glob(GlobResult(
            filenames: data["filenames"] as? [String] ?? [],
            durationMs: data["durationMs"] as? Int ?? 0,
            numFiles: data["numFiles"] as? Int ?? 0,
            truncated: data["truncated"] as? Bool ?? false
        ))
    }

    private static func parseTodoWriteResult(_ data: [String: Any]) -> ToolResultData {
        func parseTodos(_ array: [[String: Any]]?) -> [TodoItem] {
            guard let array = array else { return [] }
            return array.compactMap { item -> TodoItem? in
                guard let content = item["content"] as? String,
                      let status = item["status"] as? String else {
                    return nil
                }
                return TodoItem(
                    content: content,
                    status: status,
                    activeForm: item["activeForm"] as? String
                )
            }
        }

        return .todoWrite(TodoWriteResult(
            oldTodos: parseTodos(data["oldTodos"] as? [[String: Any]]),
            newTodos: parseTodos(data["newTodos"] as? [[String: Any]])
        ))
    }

    private static func parseTaskResult(_ data: [String: Any]) -> ToolResultData {
        return .task(TaskResult(
            agentId: data["agentId"] as? String ?? "",
            status: data["status"] as? String ?? "unknown",
            content: data["content"] as? String ?? "",
            prompt: data["prompt"] as? String,
            totalDurationMs: data["totalDurationMs"] as? Int,
            totalTokens: data["totalTokens"] as? Int,
            totalToolUseCount: data["totalToolUseCount"] as? Int
        ))
    }

    private static func parseWebFetchResult(_ data: [String: Any]) -> ToolResultData {
        return .webFetch(WebFetchResult(
            url: data["url"] as? String ?? "",
            code: data["code"] as? Int ?? 0,
            codeText: data["codeText"] as? String ?? "",
            bytes: data["bytes"] as? Int ?? 0,
            durationMs: data["durationMs"] as? Int ?? 0,
            result: data["result"] as? String ?? ""
        ))
    }

    private static func parseWebSearchResult(_ data: [String: Any]) -> ToolResultData {
        var results: [SearchResultItem] = []
        if let resultsArray = data["results"] as? [[String: Any]] {
            results = resultsArray.compactMap { item -> SearchResultItem? in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String else {
                    return nil
                }
                return SearchResultItem(
                    title: title,
                    url: url,
                    snippet: item["snippet"] as? String ?? ""
                )
            }
        }

        return .webSearch(WebSearchResult(
            query: data["query"] as? String ?? "",
            durationSeconds: data["durationSeconds"] as? Double ?? 0,
            results: results
        ))
    }

    private static func parseAskUserQuestionResult(_ data: [String: Any]) -> ToolResultData {
        var questions: [QuestionItem] = []
        if let questionsArray = data["questions"] as? [[String: Any]] {
            questions = questionsArray.compactMap { q -> QuestionItem? in
                guard let question = q["question"] as? String else { return nil }
                var options: [QuestionOption] = []
                if let optionsArray = q["options"] as? [[String: Any]] {
                    options = optionsArray.compactMap { opt -> QuestionOption? in
                        guard let label = opt["label"] as? String else { return nil }
                        return QuestionOption(
                            label: label,
                            description: opt["description"] as? String
                        )
                    }
                }
                return QuestionItem(
                    question: question,
                    header: q["header"] as? String,
                    options: options
                )
            }
        }

        var answers: [String: String] = [:]
        if let answersDict = data["answers"] as? [String: String] {
            answers = answersDict
        }

        return .askUserQuestion(AskUserQuestionResult(
            questions: questions,
            answers: answers
        ))
    }

    private static func parseBashOutputResult(_ data: [String: Any]) -> ToolResultData {
        return .bashOutput(BashOutputResult(
            shellId: data["shellId"] as? String ?? "",
            status: data["status"] as? String ?? "",
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            stdoutLines: data["stdoutLines"] as? Int ?? 0,
            stderrLines: data["stderrLines"] as? Int ?? 0,
            exitCode: data["exitCode"] as? Int,
            command: data["command"] as? String,
            timestamp: data["timestamp"] as? String
        ))
    }

    private static func parseKillShellResult(_ data: [String: Any]) -> ToolResultData {
        return .killShell(KillShellResult(
            shellId: data["shell_id"] as? String ?? data["shellId"] as? String ?? "",
            message: data["message"] as? String ?? ""
        ))
    }

    private static func parseExitPlanModeResult(_ data: [String: Any]) -> ToolResultData {
        return .exitPlanMode(ExitPlanModeResult(
            filePath: data["filePath"] as? String,
            plan: data["plan"] as? String,
            isAgent: data["isAgent"] as? Bool ?? false
        ))
    }

    // MARK: - Subagent Tools Parsing

    /// Parse subagent tools from an agent JSONL file
    func parseSubagentTools(sessionId: String, agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = Self.subagentFilePath(sessionId: sessionId, agentId: agentId, projectDir: projectDir)

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}

/// Info about a subagent tool call parsed from JSONL
struct SubagentToolInfo: Sendable {
    let id: String
    let name: String
    let input: [String: String]
    let isCompleted: Bool
    let timestamp: String?
}

// MARK: - Static Subagent Tools Parsing

extension ConversationParser {
    /// Parse subagent tools from an agent JSONL file (static, synchronous version)
    nonisolated static func parseSubagentToolsSync(sessionId: String, agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = subagentFilePath(sessionId: sessionId, agentId: agentId, projectDir: projectDir)

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}

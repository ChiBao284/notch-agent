//
//  TokenHistoryStore.swift
//  ClaudeIsland
//
//  Aggregates a year of token throughput out of every project's transcripts
//

import Foundation
import os.log

/// Builds ``TokenHistory`` by sweeping every transcript under the projects
/// directory.
///
/// The sweep is whole-corpus rather than incremental: it is a few hundred
/// megabytes on disk but only tens of thousands of lines, and the cheap
/// substring pre-filter below means almost none of them are ever decoded. The
/// result is cached against the newest transcript's modification date, so
/// repeat opens cost one `stat` per file.
actor TokenHistoryStore {
    static let shared = TokenHistoryStore()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "TokenHistory")

    /// Only `assistant` lines carry usage, and every one of them contains this.
    /// Checking for it before decoding skips the bulk of the corpus.
    private static let usageMarker = "\"usage\""

    private var cached: TokenHistory?
    /// Newest transcript modification date the cache was built from.
    private var cachedWatermark: Date?
    /// Coalesces concurrent callers onto one sweep.
    private var inFlight: Task<TokenHistory, Never>?

    /// This year's history, rebuilt only when a transcript has changed since
    /// the last sweep.
    func history(for year: Int) async -> TokenHistory {
        let files = Self.transcriptURLs()
        let watermark = Self.newestModification(of: files)

        if let cached, cached.year == year, cachedWatermark == watermark {
            return cached
        }

        if let inFlight {
            return await inFlight.value
        }

        let task = Task.detached(priority: .utility) {
            Self.sweep(files: files, year: year)
        }
        inFlight = task
        let result = await task.value
        inFlight = nil

        cached = result
        cachedWatermark = watermark
        return result
    }

    // MARK: - Sweep

    private nonisolated static func transcriptURLs() -> [URL] {
        let projects = ClaudePaths.projectsDir
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projects,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return dirs.flatMap { dir -> [URL] in
            let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
            return (contents ?? []).filter { $0.pathExtension == "jsonl" }
        }
    }

    private nonisolated static func newestModification(of files: [URL]) -> Date? {
        files.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        .max()
    }

    private nonisolated static func sweep(files: [URL], year: Int) -> TokenHistory {
        var tokensByDay: [Int: Int] = [:]
        var tokensByModel: [String: Int] = [:]
        let monthOffsets = dayOffsetsPerMonth(year: year)

        for file in files {
            // One file at a time: the corpus as a whole is far too big to hold,
            // but the largest single transcript is tens of megabytes.
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            contents.enumerateLines { line, _ in
                guard line.contains(usageMarker) else { return }
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "assistant",
                      let message = json["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let timestamp = json["timestamp"] as? String else {
                    return
                }

                guard let day = dayOfYear(fromISODate: timestamp, in: year, monthOffsets: monthOffsets) else { return }

                let tokens = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["output_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                guard tokens > 0 else { return }

                tokensByDay[day, default: 0] += tokens
                if let family = modelFamily(message["model"] as? String) {
                    tokensByModel[family, default: 0] += tokens
                }
            }
        }

        let modelTotal = tokensByModel.values.reduce(0, +)
        let share = modelTotal > 0
            ? tokensByModel.mapValues { Double($0) / Double(modelTotal) }
            : [:]

        logger.debug("Swept \(files.count, privacy: .public) transcripts: \(tokensByDay.count, privacy: .public) active days in \(year, privacy: .public)")

        return TokenHistory(
            year: year,
            tokensByDayOfYear: tokensByDay,
            modelShare: share,
            generatedAt: Date()
        )
    }

    // MARK: - Parsing

    /// Days elapsed before the 1st of each month, indexed 0...11.
    private nonisolated static func dayOffsetsPerMonth(year: Int) -> [Int] {
        let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

        var offsets: [Int] = []
        offsets.reserveCapacity(12)
        var running = 0
        for length in lengths {
            offsets.append(running)
            running += length
        }
        return offsets
    }

    /// Day-of-year from an ISO-8601 timestamp, or nil when it falls outside
    /// `year`.
    ///
    /// Reads the date straight off the "yyyy-MM-dd" prefix and adds a
    /// precomputed month offset. This runs once per assistant turn across the
    /// whole corpus — a `DateFormatter`, or even a `Calendar` round trip per
    /// line, costs far more than the rest of the sweep put together.
    private nonisolated static func dayOfYear(
        fromISODate timestamp: String,
        in year: Int,
        monthOffsets: [Int]
    ) -> Int? {
        let digits = Array(timestamp.utf8)
        guard digits.count >= 10 else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                let byte = digits[i]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }

        guard let parsedYear = number(0..<4), parsedYear == year,
              let month = number(5..<7), (1...12).contains(month),
              let day = number(8..<10), (1...31).contains(day) else {
            return nil
        }

        return monthOffsets[month - 1] + day
    }

    /// "claude-opus-5" -> "Opus". Nil for ids with no family, such as
    /// "<synthetic>" entries.
    private nonisolated static func modelFamily(_ modelId: String?) -> String? {
        guard let modelId, !modelId.hasPrefix("<") else { return nil }
        let known = ["opus", "sonnet", "haiku", "fable"]
        for token in modelId.split(separator: "-") {
            let lowered = token.lowercased()
            if known.contains(lowered) {
                return lowered.prefix(1).uppercased() + lowered.dropFirst()
            }
        }
        return nil
    }
}

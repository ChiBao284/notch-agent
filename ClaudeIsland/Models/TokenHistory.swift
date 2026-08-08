//
//  TokenHistory.swift
//  ClaudeIsland
//
//  A year of token throughput, aggregated per day from the transcripts
//

import Foundation

/// Tokens processed across every project in one calendar year, bucketed by day.
///
/// "Tokens" here counts everything the model actually read or wrote — fresh
/// input, output, and both halves of the cache. Cache reads dominate on long
/// sessions, and leaving them out reports a number two orders of magnitude
/// smaller than the work really done.
struct TokenHistory: Equatable, Sendable {
    let year: Int
    /// Tokens per day, keyed by day-of-year (1...366). Days with no work are
    /// absent rather than zero, which is what makes `activeDays` meaningful.
    let tokensByDayOfYear: [Int: Int]
    /// Share of the year's tokens by model family, e.g. "Opus" -> 0.91.
    let modelShare: [String: Double]
    let generatedAt: Date

    /// Quartile cut points over the active days, ascending. Precomputed because
    /// `intensity(forDayOfYear:)` is called once per cell in the grid.
    private let levelThresholds: [Int]

    init(year: Int, tokensByDayOfYear: [Int: Int], modelShare: [String: Double], generatedAt: Date) {
        self.year = year
        self.tokensByDayOfYear = tokensByDayOfYear
        self.modelShare = modelShare
        self.generatedAt = generatedAt

        let sorted = tokensByDayOfYear.values.sorted()
        self.levelThresholds = sorted.isEmpty
            ? []
            : (1...3).map { sorted[min(($0 * sorted.count) / 4, sorted.count - 1)] }
    }

    static let empty = TokenHistory(
        year: 0,
        tokensByDayOfYear: [:],
        modelShare: [:],
        generatedAt: .distantPast
    )

    var totalTokens: Int {
        tokensByDayOfYear.values.reduce(0, +)
    }

    var activeDays: Int {
        tokensByDayOfYear.count
    }

    var busiestDayTokens: Int {
        tokensByDayOfYear.values.max() ?? 0
    }

    /// The model family that did most of the work, with its share.
    var dominantModel: (name: String, share: Double)? {
        guard let top = modelShare.max(by: { $0.value < $1.value }) else { return nil }
        return (top.key, top.value)
    }

    /// "3.9B", "412M", "88K" — the headline figure.
    var formattedTotal: (value: String, unit: String) {
        let total = totalTokens
        if total >= 1_000_000_000 {
            return (String(format: "%.1f", Double(total) / 1_000_000_000), "B")
        }
        if total >= 1_000_000 {
            return (String(format: "%.0f", Double(total) / 1_000_000), "M")
        }
        if total >= 1_000 {
            return (String(format: "%.0f", Double(total) / 1_000), "K")
        }
        return ("\(total)", "")
    }

    /// One of four shades for the heatmap, as a quartile band over the year's
    /// own active days. Nil for a day with no work.
    ///
    /// Ranking rather than scaling, because token counts per day span several
    /// orders of magnitude: against a peak day a thousand times the quietest
    /// one, even a log ratio puts every active day above 0.6 and the grid reads
    /// as uniformly hot. Quartiles spread the shades where the data actually is.
    func intensity(forDayOfYear day: Int) -> Double? {
        guard let tokens = tokensByDayOfYear[day], tokens > 0 else { return nil }
        guard !levelThresholds.isEmpty else { return 1 }

        let level = levelThresholds.reduce(into: 0) { count, threshold in
            if tokens >= threshold { count += 1 }
        }
        return [0.25, 0.5, 0.75, 1.0][level]
    }
}

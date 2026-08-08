//
//  TokenHeatmapPanel.swift
//  ClaudeIsland
//
//  A year of token throughput as a day-per-cell heatmap
//

import SwiftUI

/// The year's token throughput: a headline total, and a cell per day shaded by
/// how much work that day carried.
///
/// Columns are weeks and rows are weekdays, so the whole year fits the panel's
/// width at a glance — 53 columns of 7.
/// `Equatable` so the caller can mark it with `.equatable()`: the grid is 371
/// views, and it shares a parent with the hover-sensitive dials, so without this
/// every hover in and out rebuilds the whole year.
struct TokenHeatmapPanel: View, Equatable {
    let history: TokenHistory
    let isLoading: Bool

    static func == (lhs: TokenHeatmapPanel, rhs: TokenHeatmapPanel) -> Bool {
        lhs.history == rhs.history && lhs.isLoading == rhs.isLoading
    }

    /// Width the grid actually got. The panel is as wide as the notch, which is
    /// `min(screenWidth * 0.4, 480)` — so it narrows on a smaller display and a
    /// fixed cell size would overflow there.
    @State private var availableWidth: CGFloat = 0

    private let gap: CGFloat = 1.5
    private let weekCount = 53

    /// Cell edge, sized so all 53 columns fit the width on offer.
    ///
    /// Starts at the floor rather than a typical size: this is a page inside a
    /// paging `ScrollView`, and a first pass wide enough to overflow its
    /// container would break the paging itself, not merely look wrong. Growing
    /// into the measured width on the next pass is the safe direction.
    private var cell: CGFloat {
        guard availableWidth > 0 else { return Self.minimumCell }
        let usable = availableWidth - CGFloat(weekCount - 1) * gap
        return max(Self.minimumCell, min(usable / CGFloat(weekCount), Self.maximumCell))
    }

    private static let minimumCell: CGFloat = 4
    private static let maximumCell: CGFloat = 7

    /// Reserved from the largest cell the grid can reach, so measuring the
    /// width doesn't change the panel's height and jolt the layout under it.
    private var gridHeight: CGFloat {
        7 * Self.maximumCell + 6 * gap
    }

    private var columnStride: CGFloat { cell + gap }

    /// Weekday of Jan 1, as a 0-based row index. The first column is short by
    /// this many cells.
    private var firstWeekdayOffset: Int {
        var components = DateComponents()
        components.year = history.year
        components.month = 1
        components.day = 1
        guard let jan1 = Calendar.current.date(from: components) else { return 0 }
        // `weekday` is 1-based from the calendar's first weekday.
        return (Calendar.current.component(.weekday, from: jan1)
            - Calendar.current.firstWeekday + 7) % 7
    }

    private var daysInYear: Int {
        let isLeap = history.year % 4 == 0 && (history.year % 100 != 0 || history.year % 400 == 0)
        return isLeap ? 366 : 365
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headline
            monthLabels
            grid
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            availableWidth = width
        }
        .opacity(isLoading ? 0.4 : 1)
        .animation(.easeOut(duration: 0.2), value: isLoading)
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(String(history.year)) TOKENS")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundColor(.notchFG.opacity(0.45))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(history.formattedTotal.value)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.notchFG)
                    Text(history.formattedTotal.unit)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.notchFG.opacity(0.5))
                }

                Text("\(history.activeDays) Active Days")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.notchFG.opacity(0.5))

                if let model = history.dominantModel {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(TerminalColors.claudeOrange)
                            .frame(width: 5, height: 5)
                        Text("\(model.name) \(Int((model.share * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.notchFG.opacity(0.45))
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Month Labels

    private var monthLabels: some View {
        // Each label is pinned to the column its month starts in, so they line
        // up with the grid instead of being spread evenly across it.
        ZStack(alignment: .leading) {
            ForEach(0..<12, id: \.self) { month in
                Text(Self.monthNames[month])
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.notchFG.opacity(0.35))
                    .offset(x: columnX(forMonth: month))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 11)
    }

    private func columnX(forMonth month: Int) -> CGFloat {
        let dayOfYear = Self.dayOffsets(year: history.year)[month]
        let column = (dayOfYear + firstWeekdayOffset) / 7
        return CGFloat(column) * columnStride
    }

    // MARK: - Grid

    private var grid: some View {
        HStack(spacing: gap) {
            ForEach(0..<weekCount, id: \.self) { week in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { weekday in
                        cellView(week: week, weekday: weekday)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: gridHeight, alignment: .top)
    }

    @ViewBuilder
    private func cellView(week: Int, weekday: Int) -> some View {
        let dayOfYear = week * 7 + weekday - firstWeekdayOffset + 1

        if dayOfYear >= 1 && dayOfYear <= daysInYear {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(fill(forDayOfYear: dayOfYear))
                .frame(width: cell, height: cell)
                .help(tooltip(forDayOfYear: dayOfYear))
        } else {
            // Padding cells before Jan 1 and after Dec 31 keep the grid square.
            Color.clear.frame(width: cell, height: cell)
        }
    }

    private func fill(forDayOfYear day: Int) -> Color {
        guard let intensity = history.intensity(forDayOfYear: day) else {
            return .notchFG.opacity(0.06)
        }
        return TerminalColors.claudeOrange.opacity(0.18 + intensity * 0.82)
    }

    private func tooltip(forDayOfYear day: Int) -> String {
        let label = Self.dateLabel(dayOfYear: day, year: history.year)
        guard let tokens = history.tokensByDayOfYear[day] else { return "\(label): no activity" }
        return "\(label): \(Self.formatted(tokens)) tokens"
    }

    // MARK: - Formatting

    private static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ]

    private static func dayOffsets(year: Int) -> [Int] {
        let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        var offsets: [Int] = []
        var running = 0
        for length in lengths {
            offsets.append(running)
            running += length
        }
        return offsets
    }

    private static func dateLabel(dayOfYear: Int, year: Int) -> String {
        var components = DateComponents()
        components.year = year
        components.day = dayOfYear
        guard let date = Calendar.current.date(from: components) else { return "" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private static func formatted(_ tokens: Int) -> String {
        if tokens >= 1_000_000_000 { return String(format: "%.2fB", Double(tokens) / 1_000_000_000) }
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.0fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }
}

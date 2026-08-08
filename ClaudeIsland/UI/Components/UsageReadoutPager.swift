//
//  UsageReadoutPager.swift
//  ClaudeIsland
//
//  Tabs between the plan usage dials and the year's token heatmap
//

import SwiftUI

/// The panel's footer: plan limits on one tab, the year's token throughput on
/// the other, switched with the tab buttons underneath.
struct UsageReadoutPager: View {
    let rateLimits: RateLimitInfo?
    let isHovering: Bool
    let onOpenClaude: () -> Void

    @State private var page: Page = .limits
    @State private var history: TokenHistory = .empty
    @State private var isLoadingHistory = false

    private enum Page: Int, CaseIterable, Identifiable {
        case limits
        case tokens

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .limits: return "Limits"
            case .tokens: return "Tokens"
            }
        }
    }

    /// Fixed so the strip keeps its height across tabs and while the heatmap's
    /// grid settles into its measured cell size.
    private static let pageHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    PlanUsagePanel(
                        rateLimits: rateLimits,
                        isHovering: isHovering,
                        onOpenClaude: onOpenClaude
                    )
                    .frame(width: proxy.size.width)

                    TokenHeatmapPanel(history: history, isLoading: isLoadingHistory)
                        // The grid is 371 views and shares a parent with the
                        // hover-sensitive dials, so without this every hover in
                        // and out rebuilds the whole year.
                        .equatable()
                        .frame(width: proxy.size.width, alignment: .top)
                }
                .offset(x: -CGFloat(page.rawValue) * proxy.size.width)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: page)
            }
            .frame(height: Self.pageHeight)
            .clipped()

            tabBar
        }
        .task {
            await loadHistory()
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases) { candidate in
                Button {
                    page = candidate
                } label: {
                    Text(candidate.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.notchFG.opacity(page == candidate ? 0.85 : 0.4))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.notchFG.opacity(page == candidate ? 0.14 : 0))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.notchFG.opacity(0.05)))
        .animation(.easeOut(duration: 0.15), value: page)
    }

    // MARK: - Data

    private func loadHistory() async {
        let year = Calendar.current.component(.year, from: Date())
        // Only the first sweep shows a loading state — later refreshes come
        // back from cache, and dimming the grid for those would just flicker.
        isLoadingHistory = history.year != year
        history = await TokenHistoryStore.shared.history(for: year)
        isLoadingHistory = false
    }
}

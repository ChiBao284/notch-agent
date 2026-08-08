//
//  PlanUsagePanel.swift
//  ClaudeIsland
//
//  Plan usage readout — the 5-hour and weekly windows shown as dials in the
//  panel's blank space, where the "Open Claude Desktop" hint used to live
//

import SwiftUI

/// The account's two rate-limit windows, drawn as labelled dials.
///
/// Sized by whatever room the session list leaves over: the full layout when
/// there is space, a single-line summary when there isn't. Returns nothing at
/// all when Claude Code hasn't reported any usage yet, so the caller can fall
/// back to the plain open-Claude hint.
struct PlanUsagePanel: View {
    let rateLimits: RateLimitInfo?
    /// Whether the pointer is anywhere over the backdrop, which lights up the
    /// open-Claude button along with it.
    let isHovering: Bool
    /// Runs when the open-Claude button is pressed.
    let onOpenClaude: () -> Void

    @ObservedObject private var account = ClaudeAccountReader.shared

    private var hasAnyUsage: Bool {
        rateLimits?.fiveHour?.usedPercentage != nil || rateLimits?.sevenDay?.usedPercentage != nil
    }

    var body: some View {
        if hasAnyUsage {
            ViewThatFits(in: .vertical) {
                fullLayout
                compactLayout
                // A long session list can leave too little room for even one
                // line. Dropping out beats drawing a clipped half-dial.
                EmptyView()
            }
        }
    }

    // MARK: - Full Layout

    private var fullLayout: some View {
        VStack(spacing: 8) {
            header

            HStack(spacing: 12) {
                dialBlock(label: "5h", window: rateLimits?.fiveHour)
                dialBlock(label: "week", window: rateLimits?.sevenDay)
            }

            openClaudeButton
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.notchFG)

            if let planLabel = account.planLabel {
                Text(planLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(.notchFG.opacity(0.55))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.notchFG.opacity(0.1))
                    )
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Sits under the dials rather than beside the title: the row it used to
    /// share with "Claude" only had room because the title is short, and the
    /// action reads as the panel's footer, not as a header accessory.
    private var openClaudeButton: some View {
        Button(action: onOpenClaude) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10))
                Text(ClaudeAppLauncher.shared.actionHint)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.notchFG.opacity(isHovering ? 0.7 : 0.4))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.notchFG.opacity(isHovering ? 0.1 : 0.05))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func dialBlock(label: String, window: RateLimitWindow?) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                UsageDial(percentage: window?.usedPercentage, size: 44, lineWidth: 3.5)

                // Left-aligned against the dial: centring these would leave the
                // label and the number floating apart at different widths.
                VStack(alignment: .leading, spacing: 0) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.notchFG.opacity(0.55))

                    percentageText(window?.usedPercentage)
                }
            }

            Text(window?.resetsInLabel ?? " ")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.notchFG.opacity(0.3))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func percentageText(_ percentage: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(percentage.map { "\(Int($0.rounded()))" } ?? "–")
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(.notchFG)

            if percentage != nil {
                Text("%")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.notchFG.opacity(0.55))
            }
        }
    }

    // MARK: - Compact Layout

    /// What's left when the session list has eaten the panel: the same numbers
    /// on one line, no reset times.
    private var compactLayout: some View {
        HStack(spacing: 14) {
            Text("Claude")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.notchFG.opacity(0.8))

            compactStat(label: "5h", window: rateLimits?.fiveHour)
            compactStat(label: "week", window: rateLimits?.sevenDay)
        }
        .frame(maxWidth: .infinity)
        .help(ClaudeAppLauncher.shared.actionHint)
    }

    private func compactStat(label: String, window: RateLimitWindow?) -> some View {
        HStack(spacing: 5) {
            UsageDial(percentage: window?.usedPercentage, size: 14, lineWidth: 2)

            Text("\(label) \(window?.usedPercentage.map { "\(Int($0.rounded()))%" } ?? "–")")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.notchFG.opacity(0.5))
        }
    }
}

// MARK: - Usage Dial

/// A percentage ring in Claude's own orange, over a faint track.
///
/// Deliberately not ``UsageLimitRing``: that one is a bare threshold-coloured
/// arc for the collapsed pill, where green/amber/red is the whole message. Here
/// the dials read as account branding, and an empty track has to stay visible
/// so a 0% or unknown window still looks like a dial.
private struct UsageDial: View {
    let percentage: Double?
    let size: CGFloat
    let lineWidth: CGFloat

    private var fraction: CGFloat {
        guard let percentage else { return 0 }
        return CGFloat(min(max(percentage, 0), 100)) / 100
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.notchFG.opacity(0.12), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    TerminalColors.claudeOrange,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

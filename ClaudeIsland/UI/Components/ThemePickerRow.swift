//
//  ThemePickerRow.swift
//  ClaudeIsland
//
//  Appearance (system / dark / light) picker for the settings menu
//

import SwiftUI

struct ThemePickerRow: View {
    @ObservedObject var themeManager: ThemeManager
    @State private var isHovered = false

    private var isExpanded: Bool {
        themeManager.isPickerExpanded
    }

    private func setExpanded(_ value: Bool) {
        themeManager.isPickerExpanded = value
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row - shows current selection
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setExpanded(!isExpanded)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: themeManager.mode.icon)
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Appearance")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(themeManager.mode.label)
                        .font(.system(size: 11))
                        .foregroundColor(.notchFG.opacity(0.4))
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.notchFG.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.notchFG.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Expanded mode list
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(AppThemeMode.allCases, id: \.self) { mode in
                        ThemeOptionRow(
                            mode: mode,
                            isSelected: themeManager.mode == mode
                        ) {
                            themeManager.select(mode)
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
    }

    private var textColor: Color {
        .notchFG.opacity(isHovered ? 1.0 : 0.7)
    }
}

// MARK: - Theme Option Row

private struct ThemeOptionRow: View {
    let mode: AppThemeMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.notchFG.opacity(0.2))
                    .frame(width: 6, height: 6)

                Image(systemName: mode.icon)
                    .font(.system(size: 10))
                    .foregroundColor(.notchFG.opacity(isHovered ? 0.8 : 0.5))
                    .frame(width: 12)

                Text(mode.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.notchFG.opacity(isHovered ? 1.0 : 0.7))

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.notchFG.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

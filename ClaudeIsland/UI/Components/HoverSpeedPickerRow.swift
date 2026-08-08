//
//  HoverSpeedPickerRow.swift
//  ClaudeIsland
//
//  Hover-to-open speed picker for the settings menu
//

import SwiftUI

struct HoverSpeedPickerRow: View {
    @ObservedObject var hoverSpeedSelector: HoverSpeedSelector
    @State private var isHovered = false
    @State private var selectedSpeed: HoverOpenSpeed = AppSettings.hoverOpenSpeed

    private var isExpanded: Bool {
        hoverSpeedSelector.isPickerExpanded
    }

    private func setExpanded(_ value: Bool) {
        hoverSpeedSelector.isPickerExpanded = value
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
                    Image(systemName: "bolt")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Hover to Open")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(selectedSpeed.label)
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

            // Expanded speed list
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(HoverOpenSpeed.allCases, id: \.self) { speed in
                        HoverSpeedOptionRow(
                            speed: speed,
                            isSelected: selectedSpeed == speed
                        ) {
                            selectedSpeed = speed
                            AppSettings.hoverOpenSpeed = speed
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
        .onAppear {
            selectedSpeed = AppSettings.hoverOpenSpeed
        }
    }

    private var textColor: Color {
        .notchFG.opacity(isHovered ? 1.0 : 0.7)
    }
}

// MARK: - Hover Speed Option Row

private struct HoverSpeedOptionRow: View {
    let speed: HoverOpenSpeed
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.notchFG.opacity(0.2))
                    .frame(width: 6, height: 6)

                Text(speed.label)
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

//
//  HoverSpeedSelector.swift
//  ClaudeIsland
//
//  Manages the expand/collapse state of the hover-open-speed picker row
//

import Combine
import Foundation

@MainActor
class HoverSpeedSelector: ObservableObject {
    static let shared = HoverSpeedSelector()

    @Published var isPickerExpanded: Bool = false

    /// Height of a single option row (matches SoundOptionRowInline style).
    private let rowHeight: CGFloat = 32

    private init() {}

    /// Extra height needed when the picker is expanded.
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        return CGFloat(HoverOpenSpeed.allCases.count) * rowHeight + 8 // +8 for padding
    }
}

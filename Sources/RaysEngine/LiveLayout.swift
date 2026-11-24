import Foundation

/// A panel of the Live window. The raw values are stored in the saved layout: never rename them.
public enum LivePanel: String, Codable, CaseIterable, Identifiable, Sendable {
    case tempo, stage, scenes, customScenes, performance
    public var id: String { rawValue }

    /// The performance panel holds the output switch, Build → Drop, Flash and Stop, so it can never be hidden.
    /// Blackout itself lives in the top bar, outside the grid.
    public var canHide: Bool { self != .performance }

    /// Panels that take the free height of the window (the stage) instead of their natural height.
    public var fillsHeight: Bool { self == .stage }
}

/// One panel in the Live grid and how many of the 12 columns it spans.
public struct LivePanelSlot: Codable, Equatable, Sendable, Identifiable {
    public var panel: LivePanel
    public var span: Int
    public var id: LivePanel { panel }

    public init(_ panel: LivePanel, span: Int) {
        self.panel = panel
        self.span = LiveLayout.clampSpan(span)
    }
}

/// The user's arrangement of the Live window: an ordered list of panels on a 12-column grid.
/// Panels flow left to right and wrap to a new row when the next one does not fit.
///
/// Pure value type: the app edits it in Layout mode and saves it as JSON in the preferences.
/// Decoding is tolerant, so a layout saved by a newer or older RAYS always opens.
public struct LiveLayout: Codable, Equatable, Sendable {
    public static let columns = 12
    /// Widths offered by the narrower / wider buttons, in columns.
    public static let spanSteps = [3, 4, 6, 8, 9, 12]

    public private(set) var slots: [LivePanelSlot]

    public init(_ slots: [LivePanelSlot]) {
        self.slots = Self.normalized(slots)
    }

    // MARK: Presets

    public enum Preset: String, CaseIterable, Identifiable, Sendable {
        case classic, tempoRight, bigStage, minimal
        public var id: String { rawValue }

        public var layout: LiveLayout {
            switch self {
            case .classic:
                return LiveLayout([
                    .init(.tempo, span: 3), .init(.stage, span: 9), .init(.scenes, span: 12),
                    .init(.customScenes, span: 12), .init(.performance, span: 12),
                ])
            case .tempoRight:
                return LiveLayout([
                    .init(.stage, span: 9), .init(.tempo, span: 3), .init(.scenes, span: 12),
                    .init(.customScenes, span: 12), .init(.performance, span: 12),
                ])
            case .bigStage:
                return LiveLayout([
                    .init(.stage, span: 12), .init(.scenes, span: 12), .init(.customScenes, span: 12), .init(.performance, span: 12),
                ])
            case .minimal:
                return LiveLayout([.init(.stage, span: 12), .init(.scenes, span: 12), .init(.performance, span: 12)])
            }
        }
    }

    /// The arrangement RAYS had before layouts were editable.
    public static let standard = Preset.classic.layout

    // MARK: Queries

    public var visiblePanels: [LivePanel] { slots.map(\.panel) }
    public var hiddenPanels: [LivePanel] { LivePanel.allCases.filter { !contains($0) } }
    public func contains(_ panel: LivePanel) -> Bool { slots.contains { $0.panel == panel } }
    public func span(of panel: LivePanel) -> Int? { slots.first { $0.panel == panel }?.span }

    /// Slots grouped in rows, left to right, wrapping when the next panel does not fit in 12 columns.
    public var rows: [[LivePanelSlot]] {
        var rows: [[LivePanelSlot]] = []
        var current: [LivePanelSlot] = []
        var used = 0
        for slot in slots {
            if used + slot.span > Self.columns, !current.isEmpty {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(slot)
            used += slot.span
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    // MARK: Editing

    /// Moves `panel` to the position of `target` (dropping a panel onto another one).
    public mutating func move(_ panel: LivePanel, to target: LivePanel) {
        guard panel != target, let from = index(of: panel), let to = index(of: target) else { return }
        let slot = slots.remove(at: from)
        slots.insert(slot, at: to)
    }

    /// Moves `panel` one place earlier (-1) or later (+1) in the reading order.
    public mutating func shift(_ panel: LivePanel, by offset: Int) {
        guard let from = index(of: panel) else { return }
        let to = min(max(from + offset, 0), slots.count - 1)
        guard to != from else { return }
        slots.swapAt(from, to)
    }

    public func canShift(_ panel: LivePanel, by offset: Int) -> Bool {
        guard let i = index(of: panel) else { return false }
        return slots.indices.contains(i + offset)
    }

    /// Next wider (+1) or narrower (-1) step of `spanSteps`.
    public mutating func resize(_ panel: LivePanel, step: Int) {
        guard let i = index(of: panel) else { return }
        slots[i].span = Self.steppedSpan(from: slots[i].span, step: step)
    }

    public func canResize(_ panel: LivePanel, step: Int) -> Bool {
        guard let span = span(of: panel) else { return false }
        return Self.steppedSpan(from: span, step: step) != span
    }

    public mutating func hide(_ panel: LivePanel) {
        guard panel.canHide else { return }
        slots.removeAll { $0.panel == panel }
    }

    /// Shows a hidden panel at the end, at full width.
    public mutating func show(_ panel: LivePanel) {
        guard !contains(panel) else { return }
        slots.append(LivePanelSlot(panel, span: Self.columns))
    }

    // MARK: Rules

    static func clampSpan(_ span: Int) -> Int { min(max(span, spanSteps[0]), columns) }

    static func steppedSpan(from span: Int, step: Int) -> Int {
        if step > 0 { return spanSteps.first { $0 > span } ?? span }
        if step < 0 { return spanSteps.last { $0 < span } ?? span }
        return span
    }

    /// One slot per panel, spans in range, and the performance panel always present.
    static func normalized(_ slots: [LivePanelSlot]) -> [LivePanelSlot] {
        var seen = Set<LivePanel>()
        var result = slots.filter { seen.insert($0.panel).inserted }.map { LivePanelSlot($0.panel, span: $0.span) }
        if !seen.contains(.performance) { result.append(LivePanelSlot(.performance, span: columns)) }
        return result
    }

    private func index(of panel: LivePanel) -> Int? { slots.firstIndex { $0.panel == panel } }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case slots }
    private enum SlotKeys: String, CodingKey { case panel, span }

    /// Unknown panels (from a newer RAYS) and malformed entries are skipped instead of failing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .slots)
        var slots: [LivePanelSlot] = []
        while !list.isAtEnd {
            guard let entry = try? list.nestedContainer(keyedBy: SlotKeys.self) else {
                _ = try? list.decode(AnyDecodable.self)
                continue
            }
            guard let raw = try? entry.decode(String.self, forKey: .panel), let panel = LivePanel(rawValue: raw) else { continue }
            let span = (try? entry.decode(Int.self, forKey: .span)) ?? Self.columns
            slots.append(LivePanelSlot(panel, span: span))
        }
        self.init(slots)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slots, forKey: .slots)
    }

    /// Reads a saved layout; anything unreadable falls back to `standard`.
    public static func decodeSaved(_ data: Data?) -> LiveLayout {
        guard let data, let layout = try? JSONDecoder().decode(LiveLayout.self, from: data) else { return .standard }
        return layout
    }
}

/// Consumes one element of any shape from an unkeyed container.
private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

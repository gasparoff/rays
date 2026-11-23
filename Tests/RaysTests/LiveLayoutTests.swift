import XCTest
@testable import RaysEngine

final class LiveLayoutTests: XCTestCase {
    func testStandardLayoutMatchesTheFixedWindowOfEarlierVersions() {
        let layout = LiveLayout.standard
        XCTAssertEqual(layout.visiblePanels, [.tempo, .stage, .scenes, .customScenes, .performance])
        XCTAssertEqual(layout.rows.map { $0.map(\.panel) }, [[.tempo, .stage], [.scenes], [.customScenes], [.performance]])
        XCTAssertTrue(layout.hiddenPanels.isEmpty)
    }

    func testRowsWrapWhenTheNextPanelDoesNotFit() {
        let layout = LiveLayout([
            .init(.stage, span: 8), .init(.tempo, span: 4), .init(.scenes, span: 9), .init(.customScenes, span: 4),
            .init(.performance, span: 12),
        ])
        XCTAssertEqual(layout.rows.map { $0.map(\.panel) }, [[.stage, .tempo], [.scenes], [.customScenes], [.performance]])
        for row in layout.rows { XCTAssertLessThanOrEqual(row.map(\.span).reduce(0, +), LiveLayout.columns) }
    }

    func testMoveAndShiftReorderPanels() {
        var layout = LiveLayout.standard
        layout.move(.performance, to: .tempo)
        XCTAssertEqual(layout.visiblePanels, [.performance, .tempo, .stage, .scenes, .customScenes])
        layout.shift(.performance, by: 1)
        XCTAssertEqual(layout.visiblePanels.prefix(2), [.tempo, .performance])
        XCTAssertFalse(layout.canShift(.tempo, by: -1))
        layout.shift(.tempo, by: -1)
        XCTAssertEqual(layout.visiblePanels.first, .tempo, "Shifting past the start is ignored")
    }

    func testResizeStepsThroughAllowedWidthsAndStopsAtTheEnds() {
        var layout = LiveLayout.standard
        layout.resize(.tempo, step: 1)
        XCTAssertEqual(layout.span(of: .tempo), 4)
        layout.resize(.tempo, step: -1)
        layout.resize(.tempo, step: -1)
        XCTAssertEqual(layout.span(of: .tempo), 3)
        XCTAssertFalse(layout.canResize(.tempo, step: -1))
        XCTAssertFalse(layout.canResize(.performance, step: 1))
        XCTAssertEqual(LivePanelSlot(.stage, span: 40).span, 12)
        XCTAssertEqual(LivePanelSlot(.stage, span: 0).span, 3)
    }

    /// Blackout lives in the performance panel: no layout may hide it.
    func testPerformancePanelCanNeverBeHidden() throws {
        var layout = LiveLayout.standard
        layout.hide(.performance)
        XCTAssertTrue(layout.contains(.performance))
        layout.hide(.tempo)
        XCTAssertEqual(layout.hiddenPanels, [.tempo])
        layout.show(.tempo)
        XCTAssertEqual(layout.visiblePanels.last, .tempo)

        XCTAssertTrue(LiveLayout([.init(.stage, span: 12)]).contains(.performance))
        let saved = Data(#"{"slots":[{"panel":"stage","span":12}]}"#.utf8)
        XCTAssertTrue(LiveLayout.decodeSaved(saved).contains(.performance))
        for preset in LiveLayout.Preset.allCases { XCTAssertTrue(preset.layout.contains(.performance), "\(preset)") }
    }

    func testRoundTripAndTolerantDecoding() throws {
        var layout = LiveLayout.Preset.bigStage.layout
        layout.resize(.scenes, step: -1)
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(LiveLayout.self, from: data), layout)

        // A layout saved by a newer version: unknown panel, duplicate, missing and out-of-range spans.
        let json =
            #"{"slots":[{"panel":"midiMonitor","span":6},{"panel":"stage","span":99},{"panel":"stage","span":4},"#
            + #"{"panel":"tempo"},{"span":3},7,{"panel":"performance","span":12}],"extra":true}"#
        let newer = Data(json.utf8)
        let decoded = LiveLayout.decodeSaved(newer)
        XCTAssertEqual(decoded.slots, [.init(.stage, span: 12), .init(.tempo, span: 12), .init(.performance, span: 12)])

        XCTAssertEqual(LiveLayout.decodeSaved(nil), .standard)
        XCTAssertEqual(LiveLayout.decodeSaved(Data("not json".utf8)), .standard)
    }

    /// The raw values are written to the preferences: renaming a case would reset saved layouts.
    func testStoredPanelNamesAreStable() {
        XCTAssertEqual(LivePanel.allCases.map(\.rawValue), ["tempo", "stage", "scenes", "customScenes", "performance"])
    }
}

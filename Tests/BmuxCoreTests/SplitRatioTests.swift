import Foundation
import Testing
@testable import BmuxApp

@Test func splitRatioKeepsBothPanesVisible() {
    #expect(abs(SplitRatio.clamp(0, available: 300) - 32.0 / 300.0) < 0.000_001)
    #expect(abs(SplitRatio.clamp(1, available: 300) - 268.0 / 300.0) < 0.000_001)
    #expect(SplitRatio.clamp(0.2, available: 60) == 0.5)
}

@Test func splitRatioCanUseAlmostAllAvailableSpaceAndSurvivePersistence() throws {
    let first = Pane()
    let second = Pane()
    let id = UUID()
    var node = SplitNode.split(id: id, direction: .sideBySide, ratio: 0.5,
                               first: .pane(first), second: .pane(second))
    let ratio = SplitRatio.clamp(1, available: 1_000)
    #expect(ratio == 0.968)
    node.setRatio(node: id, ratio)
    let restored = try JSONDecoder().decode(SplitNode.self, from: JSONEncoder().encode(node))
    guard case .split(_, _, let savedRatio, _, _) = restored else {
        Issue.record("Expected split layout")
        return
    }
    #expect(savedRatio == ratio)
    #expect(SplitRatio.clamp(savedRatio, available: 1_000) == ratio)
}

@Test func splitResizeSnapsToCellsIncludingPaddingAndRetinaDimensions() {
    // Fractional point widths are normal on a Retina display. Both axes
    // use the same math, with their actual font cell width or height.
    for cell in [7.5, 16.0] {
        let grid = TerminalResizeGrid(cell: cell, padding: 12)
        for requested in stride(from: 0.0, through: 1.0, by: 0.013) {
            let ratio = SplitRatio.snap(requested, available: 999, grid: grid)
            let dimension = ratio * 999
            let cells = (dimension - 12) / cell
            #expect(abs(cells - cells.rounded()) < 0.000_001)
            #expect(dimension >= 32)
            #expect(999 - dimension >= 32)
            #expect(abs(SplitRatio.snap(ratio, available: 999, grid: grid) - ratio) < 0.000_001)
        }
    }
    #expect(SplitRatio.snap(0.2, available: 60, grid: .init(cell: 16, padding: 12)) == 0.5)
    #expect(SplitRatio.snap(0.4, available: 999, grid: nil) == SplitRatio.clamp(0.4, available: 999))
}

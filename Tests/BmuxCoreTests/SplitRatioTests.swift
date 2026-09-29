import Testing
@testable import BmuxApp

@Test func splitRatioKeepsBothPanesVisible() {
    #expect(abs(SplitRatio.clamp(0.1, available: 300) - 80.0 / 300.0) < 0.000_001)
    #expect(abs(SplitRatio.clamp(0.9, available: 300) - 220.0 / 300.0) < 0.000_001)
    #expect(SplitRatio.clamp(0.2, available: 100) == 0.5)
}

@Test func splitRatioMatchesPersistedLimitsInWideWindows() {
    #expect(SplitRatio.clamp(0, available: 1_000) == 0.1)
    #expect(SplitRatio.clamp(1, available: 1_000) == 0.9)
}

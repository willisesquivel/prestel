import Testing
@testable import Prestel

struct TerminalFindTests {
    private func hits(_ text: String, _ query: String, caseSensitive: Bool = false,
                      widths: [Int]? = nil) -> [TerminalFindHighlight] {
        TerminalFindMatcher.highlights(
            row: 3, text: text, cellWidths: widths ?? Array(repeating: 1, count: text.count),
            query: query, caseSensitive: caseSensitive)
    }

    @Test func findsEveryNonOverlappingMatch() {
        #expect(hits("abcabcab", "abc") == [
            TerminalFindHighlight(row: 3, column: 0, width: 3),
            TerminalFindHighlight(row: 3, column: 3, width: 3)
        ])
        #expect(hits("aaaa", "aa").count == 2)
    }

    @Test func caseSensitivityIsHonored() {
        #expect(hits("Error error ERROR", "error").count == 3)
        #expect(hits("Error error ERROR", "error", caseSensitive: true).count == 1)
    }

    @Test func emptyQueryAndTextMatchNothing() {
        #expect(hits("hello", "").isEmpty)
        #expect(hits("", "a", widths: []).isEmpty)
        #expect(hits("ab", "abc").isEmpty)
    }

    @Test func wideCellsShiftColumns() {
        // The wide character takes cells 0-1, so "x" sits at column 2.
        #expect(hits("日x", "x", widths: [2, 0, 1]) == [TerminalFindHighlight(row: 3, column: 2, width: 1)])
        #expect(hits("日x", "日", widths: [2, 0, 1]) == [TerminalFindHighlight(row: 3, column: 0, width: 2)])
    }

    @Test func counterText() {
        #expect(TerminalFindMatcher.counter(index: 3, total: 12) == "3 of 12")
        #expect(TerminalFindMatcher.counter(index: 0, total: 4) == "4")
        #expect(TerminalFindMatcher.counter(index: 0, total: 0) == "No results")
        #expect(TerminalFindMatcher.counter(index: 5, total: 1000) == "5 of 1000+")
    }
}

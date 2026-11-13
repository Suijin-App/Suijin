import Foundation
import Testing
@testable import SuijinDiff

struct WordDiffTests {
    private func pieces(_ text: String, _ ranges: [NSRange]) -> [String] {
        ranges.map { (text as NSString).substring(with: $0) }
    }

    @Test func marksOnlyTheChangedWord() {
        let old = "let name = \"old\""
        let new = "let name = \"new\""
        let result = WordDiff.changes(old: old, new: new)
        #expect(pieces(old, result.old) == ["old"])
        #expect(pieces(new, result.new) == ["new"])
    }

    @Test func insertionHasNoOldRange() {
        let old = "func start(_ agent: Agent) {"
        let new = "func start(_ agent: Agent, timeout: Duration) {"
        let result = WordDiff.changes(old: old, new: new)
        #expect(result.old.isEmpty)
        #expect(pieces(new, result.new) == [", timeout: Duration"])
    }

    @Test func separateChangesStaySeparate() {
        let old = "a + b * c"
        let new = "x + b / c"
        let result = WordDiff.changes(old: old, new: new)
        #expect(pieces(old, result.old) == ["a", "*"])
        #expect(pieces(new, result.new) == ["x", "/"])
    }

    @Test func identicalLinesHaveNoChanges() {
        #expect(WordDiff.changes(old: "same", new: "same") == .none)
    }

    @Test func rewrittenLinesAreNotMarked() {
        #expect(WordDiff.changes(old: "return totalCount", new: "throw Failure.timeout(seconds)") == .none)
    }

    @Test func rangesAreUTF16Offsets() {
        let old = "let 🚀 = \"ä\""
        let new = "let 🚀 = \"ö\""
        let result = WordDiff.changes(old: old, new: new)
        #expect(pieces(old, result.old) == ["ä"])
        #expect(pieces(new, result.new) == ["ö"])
        #expect(result.new.first?.location == 10)
    }

    @Test func veryLongLinesFallBackToPrefixAndSuffix() {
        let old = (0..<800).map { "w\($0)" }.joined(separator: " ")
        let new = old.replacingOccurrences(of: "w400 ", with: "changed ")
        let result = WordDiff.changes(old: old, new: new)
        #expect(pieces(old, result.old) == ["w400"])
        #expect(pieces(new, result.new) == ["changed"])
    }
}

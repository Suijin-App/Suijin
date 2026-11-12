import Foundation

/// Word-level differences between an old and a new version of one line, for highlighting what changed inside a
/// modified line. Lines are split into words (letters, digits and `_`), whitespace runs and single other
/// characters; the longest common subsequence of those tokens is kept, the rest is reported as changed.
///
/// Ranges are UTF-16 offsets into each line. When the lines share too little, nothing is reported: the whole line is
/// already marked as changed and scattered word marks would only be noise.
public enum WordDiff {
    public struct Result: Sendable, Hashable {
        public var old: [NSRange]
        public var new: [NSRange]

        public init(old: [NSRange], new: [NSRange]) {
            self.old = old
            self.new = new
        }

        public static let none = Result(old: [], new: [])
    }

    /// Below this share of unchanged non-whitespace characters (of the longer line) the lines count as rewritten.
    static let minimumSharedFraction = 0.3
    /// Token count product above which the quadratic subsequence search is skipped for a prefix/suffix comparison.
    static let maximumCells = 250_000

    public static func changes(old: String, new: String) -> Result {
        guard old != new else { return .none }
        let a = tokens(old)
        let b = tokens(new)

        // Common prefix and suffix first: most edits touch one place, which keeps the search small.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix].text == b[prefix].text { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix].text == b[b.count - 1 - suffix].text { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])

        var keptA = [Bool](repeating: false, count: midA.count)
        var keptB = [Bool](repeating: false, count: midB.count)
        if !midA.isEmpty, !midB.isEmpty, midA.count * midB.count <= maximumCells {
            commonSubsequence(midA, midB, keptA: &keptA, keptB: &keptB)
        }

        let sharedA = a[..<prefix] + a[(a.count - suffix)...] + zip(midA, keptA).filter(\.1).map(\.0)
        let shared = sharedA.filter { !$0.isWhitespace }.reduce(0) { $0 + $1.range.length }
        let longest = max(nonWhitespaceLength(a), nonWhitespaceLength(b))
        guard longest > 0, Double(shared) / Double(longest) >= minimumSharedFraction else { return .none }

        return Result(old: merged(zip(midA, keptA).filter { !$0.1 }.map(\.0.range)),
                      new: merged(zip(midB, keptB).filter { !$0.1 }.map(\.0.range)))
    }

    // MARK: - Tokens

    struct Token {
        var text: Substring
        var range: NSRange
        var isWhitespace: Bool
    }

    static func tokens(_ line: String) -> [Token] {
        enum Class { case word, space, other }
        func classify(_ scalar: Unicode.Scalar) -> Class {
            if scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return .word }
            if scalar.properties.isWhitespace { return .space }
            return .other
        }
        var result: [Token] = []
        var index = line.startIndex
        var offset = 0
        while index < line.endIndex {
            let start = index
            let startOffset = offset
            let kind = classify(line.unicodeScalars[index])
            var length = 0
            repeat {
                let scalar = line.unicodeScalars[index]
                length += scalar.utf16.count
                index = line.unicodeScalars.index(after: index)
            } while kind != .other && index < line.endIndex && classify(line.unicodeScalars[index]) == kind
            offset += length
            result.append(Token(text: Substring(line.unicodeScalars[start..<index]),
                                range: NSRange(location: startOffset, length: length), isWhitespace: kind == .space))
        }
        return result
    }

    private static func nonWhitespaceLength(_ tokens: [Token]) -> Int {
        tokens.filter { !$0.isWhitespace }.reduce(0) { $0 + $1.range.length }
    }

    /// Marks the tokens of one longest common subsequence of `a` and `b`.
    private static func commonSubsequence(_ a: [Token], _ b: [Token], keptA: inout [Bool], keptB: inout [Bool]) {
        let n = a.count
        let m = b.count
        // lengths[i][j]: LCS length of a[i...] and b[j...], flattened.
        var lengths = [Int](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i * (m + 1) + j] = a[i].text == b[j].text
                    ? lengths[(i + 1) * (m + 1) + j + 1] + 1
                    : max(lengths[(i + 1) * (m + 1) + j], lengths[i * (m + 1) + j + 1])
            }
        }
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i].text == b[j].text {
                keptA[i] = true
                keptB[j] = true
                i += 1
                j += 1
            } else if lengths[(i + 1) * (m + 1) + j] >= lengths[i * (m + 1) + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
    }

    /// Joins ranges that touch, so a changed run reads as one mark.
    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges {
            if let last = result.last, NSMaxRange(last) == range.location {
                result[result.count - 1].length += range.length
            } else {
                result.append(range)
            }
        }
        return result
    }
}

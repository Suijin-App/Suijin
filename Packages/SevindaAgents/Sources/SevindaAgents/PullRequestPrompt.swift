import Foundation

/// The prompt that asks an agent for a pull request title and body, and the parser for its answer.
public enum PullRequestPrompt {
    /// A generated pull request text.
    public struct Draft: Hashable, Sendable {
        public var title: String
        public var body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// `commits` are the full messages of the branch's commits since `base` (oldest first); `diff` is the branch's
    /// diff against its merge base with `base`.
    public static func make(branch: String, base: String, commits: [String], diff: String,
                            budget: Int = CommitMessagePrompt.diffBudget) -> String {
        let commitList = commits.prefix(50).map { message in
            message.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .map { $0.offset == 0 ? "- " + $0.element : "  " + $0.element }.joined(separator: "\n")
        }
        return """
        You are writing the title and description of a GitHub pull request that merges the branch "\(branch)" into \
        "\(base)".
        Do not use any tools and do not change any files: everything you need is in this prompt.

        Answer in exactly this format:
        - Line 1: the title, at most 72 characters, no trailing period, no "Title:" label.
        - Line 2: empty.
        - Then the description in GitHub Markdown: a short summary of what changed and why, then a "## Changes" list.
          Mention how it was tested only if the commits or diff show it. Do not invent issue numbers or links.
        Output ONLY the title and description: no preamble, no code fences around the whole answer.

        Commits on the branch (oldest first):
        \(commitList.isEmpty ? "(none)" : commitList.joined(separator: "\n"))

        Diff against \(base):
        ```diff
        \(CommitMessagePrompt.truncateDiff(diff, budget: budget))
        ```

        """
    }

    /// Splits an answer into title (first non-empty line, without a `Title:` label or Markdown heading marks) and
    /// body (the rest). Nil when the answer has no title line.
    public static func parse(_ answer: String) -> Draft? {
        var lines = answer.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard var title = lines.popFirst()?.trimmingCharacters(in: .whitespaces) else { return nil }
        while title.hasPrefix("#") { title.removeFirst() }
        title = title.trimmingCharacters(in: .whitespaces)
        for label in ["Title:", "title:", "**Title:**"] where title.hasPrefix(label) {
            title = String(title.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        if title.count > 1, title.hasPrefix("\""), title.hasSuffix("\"") { title = String(title.dropFirst().dropLast()) }
        guard !title.isEmpty else { return nil }
        var body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["Description:", "Body:", "**Description:**"] where body.hasPrefix(label) {
            body = String(body.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Draft(title: title, body: body)
    }
}

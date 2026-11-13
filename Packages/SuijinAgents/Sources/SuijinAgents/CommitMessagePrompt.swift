import Foundation

/// The prompt that asks an agent for a commit message, and the diff budget shared with `PullRequestPrompt`.
public enum CommitMessagePrompt {
    /// Characters of diff sent to the agent. Larger diffs are cut fairly per file (see `truncateDiff`).
    public static let diffBudget = 120_000

    /// `stagedDiff` is `git diff --cached`; `recentSubjects` are the latest commit subjects (newest first), so the
    /// agent can follow the repository's style (Conventional Commits, ticket prefixes, tense).
    public static func make(stagedDiff: String, recentSubjects: [String], budget: Int = diffBudget) -> String {
        var prompt = """
        You are writing a single git commit message for the staged changes below.
        Do not use any tools and do not change any files: everything you need is in this prompt.

        Rules:
        - First line: a summary in the imperative mood, at most 72 characters, no trailing period.
        - Optional body: one blank line, then lines wrapped at 72 characters explaining what changed and why.
        - Follow the style of the recent commit subjects if they share one (for example a "feat:" / "fix:" prefix).
        - Output ONLY the commit message: no preamble, no code fences, no quotes, no trailers such as Co-authored-by.

        """
        let subjects = recentSubjects.prefix(10).map { "- " + $0 }
        if !subjects.isEmpty {
            prompt += "\nRecent commit subjects (newest first):\n" + subjects.joined(separator: "\n") + "\n"
        }
        prompt += "\nStaged diff:\n```diff\n" + truncateDiff(stagedDiff, budget: budget) + "\n```\n"
        return prompt
    }

    /// Cuts `diff` to `budget` characters. Each file (`diff --git` section) gets a fair share, and the room a small
    /// file does not use goes to the others, so one huge generated file cannot crowd out the human-written changes.
    /// Cuts fall on line boundaries where possible and are marked.
    public static func truncateDiff(_ diff: String, budget: Int) -> String {
        guard diff.count > budget else { return diff }
        let sections = splitSections(diff)
        let shares = allocate(sizes: sections.map(\.count), budget: budget)
        return zip(sections, shares).map { clip($0, to: $1) }.joined()
    }

    static func splitSections(_ diff: String) -> [String] {
        var sections: [String] = []
        var current = ""
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git "), !current.isEmpty {
                sections.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { sections.append(String(current.dropLast())) }
        return sections
    }

    static func allocate(sizes: [Int], budget: Int) -> [Int] {
        var shares = Array(repeating: 0, count: sizes.count)
        var active = Array(sizes.indices)
        var remaining = budget
        while !active.isEmpty, remaining > 0 {
            let share = remaining / active.count
            guard share > 0 else { break }
            var stillActive: [Int] = []
            for index in active {
                let grant = min(sizes[index] - shares[index], share)
                shares[index] += grant
                remaining -= grant
                if shares[index] < sizes[index] { stillActive.append(index) }
            }
            active = stillActive
        }
        return shares
    }

    static func clip(_ section: String, to limit: Int) -> String {
        guard section.count > limit else { return section }
        let marker = "\n… (diff truncated, \(section.count - limit) characters omitted)\n"
        guard limit > marker.count else { return limit > 0 ? String(marker.prefix(limit)) : "" }
        let head = section.prefix(limit - marker.count)
        // Back up to the last full line unless that throws away most of the share (one very long line).
        if let newline = head.lastIndex(of: "\n"), head.distance(from: head.startIndex, to: newline) > head.count / 2 {
            return String(head[..<newline]) + marker
        }
        return String(head) + marker
    }
}

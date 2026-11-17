import AppKit
import OSLog
import SuijinGit
import SwiftUI
import Testing
@testable import Suijin

/// The Changes file list filling with hundreds of files at once, as `DiffScreen` does when a checkout's changes load.
@MainActor
@Suite(.serialized)
struct ChangedFilesListTableTests {
    @Observable
    @MainActor
    final class Holder {
        var sections: [ChangeSection] = []
        var selection: ChangeSelection?
        var isLoading = true
    }

    struct Host: View {
        @Bindable var holder: Holder

        var body: some View {
            ChangedFilesList(sections: holder.sections, selection: $holder.selection, isLoading: holder.isLoading,
                             error: nil, emptyDescription: Text(verbatim: "Nothing"), selectedCommit: .constant(nil))
        }
    }

    /// `count` committed files, most in folders (two-line rows), some at the top level (one-line rows), and a few commits.
    static func sections(files count: Int) -> [ChangeSection] {
        let files = (0..<count).map { index in
            ChangedFile(path: index % 7 == 0 ? "file-\(index).css" : "src/module-\(index % 13)/file-\(index).swift",
                        kind: index % 5 == 0 ? .deleted : .modified)
        }.sorted { $0.path < $1.path }
        let commits = (0..<12).map { index in
            CommitSummary(sha: String(format: "%040d", index), shortSHA: "abc\(index)", subject: "Commit \(index)",
                          author: "Suijin Tests", date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3600))
        }
        return [
            ChangeSection(group: .uncommitted, title: Text(verbatim: "Uncommitted"), detail: Text(verbatim: "1 file"),
                          files: [ChangedFile(path: "assets-plugins.css", kind: .added)]),
            ChangeSection(group: .committed, title: Text(verbatim: "Committed"), detail: Text(verbatim: "12 commits"),
                          files: files, commits: commits),
        ]
    }

    /// Messages AppKit logged in this process since `start` that report a reentrant table view update.
    static func reentrancyWarnings(since start: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        return try store.getEntries(at: store.position(date: start))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.date >= start }
            .map(\.composedMessage)
            .filter { $0.contains("reentrant operation in its NSTableView delegate") }
    }

    /// The table view the list is drawn with.
    static func tableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = tableView(in: subview) { return table }
        }
        return nil
    }

    /// From an empty list (a checkout's changes loading) and from a short one (the "unsent notes" filter turned off).
    @Test(arguments: [(0, 238), (0, 927), (3, 927)])
    func fillingTheListLogsNoReentrantTableUpdateAndListsEveryFile(from: Int, to: Int) async throws {
        let holder = Holder()
        if from > 0 {
            holder.sections = Self.sections(files: from)
            holder.isLoading = false
        }
        let window = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(holder: holder))
        defer { window.close() }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .seconds(0.3))

        let start = Date()
        // As `DiffScreen.reloadFiles` does: the lists, the end of loading and the first selection in one update.
        let sections = Self.sections(files: to)
        holder.sections = sections
        holder.isLoading = false
        holder.selection = sections.first.flatMap { section in section.files.first.map { ChangeSelection(group: section.group, path: $0.path) } }
        try await Task.sleep(for: .seconds(1.0))
        window.displayIfNeeded()
        try await Task.sleep(for: .seconds(0.5))

        #expect(try Self.reentrancyWarnings(since: start).isEmpty)
        // Every file made it into the table, past the first batch: the file rows plus the uncommitted one.
        let table = try #require(window.contentView.flatMap(Self.tableView(in:)))
        #expect(table.numberOfRows > to + 1)
    }

    @Test func limitedKeepsTheFirstFilesInListOrder() {
        let sections = Self.sections(files: 10)
        let limited = ChangedFilesList.limited(sections, files: 4)
        // The one uncommitted file, then three committed ones; the committed section keeps its commits.
        #expect(limited.map(\.files.count) == [1, 3])
        #expect(limited[1].files == Array(sections[1].files.prefix(3)))
        #expect(limited[1].commits == sections[1].commits)
        #expect(ChangedFilesList.limited(sections, files: nil).map(\.files) == sections.map(\.files))

        // A section left with no files and no commits is dropped, not shown as an empty heading.
        let withoutCommits = sections.map { ChangeSection(group: $0.group, title: $0.title, detail: $0.detail, files: $0.files) }
        #expect(ChangedFilesList.limited(withoutCommits, files: 1).map(\.group) == [.uncommitted])
    }
}

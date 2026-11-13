import Darwin
import Foundation
import Testing
@testable import SevindaAccounts

/// Moving a conversation's history to another account's folder: where Claude Code and Codex keep it, that the files
/// are placed without ever replacing a different one, and that nothing but history files is written. Everything runs
/// in a throwaway folder.
@Suite struct ConversationTransferTests {
    let sandbox: Sandbox
    let id = "0b6f8f3e-4c1a-4d7e-9a51-2f3c4d5e6f70"

    init() throws {
        sandbox = try Sandbox()
    }

    private var managedA: URL { sandbox.dataRoot.appendingPathComponent("claude-profiles/a/home", isDirectory: true) }
    private var managedB: URL { sandbox.dataRoot.appendingPathComponent("claude-profiles/b/home", isDirectory: true) }

    // MARK: Claude folder names

    @Test func claudeFolderNamesReplaceEverythingButLettersAndDigits() {
        #expect(ConversationTransfer.claudeProjectFolder(forCwd: "/Users/someone/Self-Works/Mercury") == "-Users-someone-Self-Works-Mercury")
        // Underscores, dots and spaces become dashes too, as in Claude's own `projects` folder.
        #expect(ConversationTransfer.claudeProjectFolder(forCwd: "/private/var/folders/mn/dqx_4n7d/T/a b.c")
            == "-private-var-folders-mn-dqx-4n7d-T-a-b-c")
        // One dash per UTF-16 unit: an accented letter is one unit, an emoji two.
        #expect(ConversationTransfer.claudeProjectFolder(forCwd: "/Café/😀") == "-Caf----")
    }

    @Test func longClaudeFolderNamesAreCutAndHashed() {
        let path = "/" + String(repeating: "a", count: 250)
        let name = ConversationTransfer.claudeProjectFolder(forCwd: path)
        #expect(name.hasPrefix("-" + String(repeating: "a", count: 199) + "-"))
        // The hash Claude Code computes in JavaScript: h = (h << 5) - h + unit, as a 32-bit integer.
        var expected: Int32 = 0
        for unit in path.utf16 { expected = expected &* 31 &+ Int32(unit) }
        #expect(name == String(name.prefix(200)) + "-" + String(abs(Int64(expected)), radix: 36))
        #expect(ConversationTransfer.javaStyleHash("hello") == 99_162_322)
        // Exactly 200 characters is kept as it is.
        let exact = "/" + String(repeating: "b", count: 199)
        #expect(ConversationTransfer.claudeProjectFolder(forCwd: exact).count == 200)
    }

    // MARK: Claude

    @Test func claudeTranscriptAndItsFolderAreLinkedUnderTheTargetsProject() throws {
        let cwd = sandbox.base.appendingPathComponent("work").path
        try sandbox.mkdir(URL(fileURLWithPath: cwd))
        let folder = ConversationTransfer.claudeProjectFolder(forCwd: cwd)
        let source = managedA.appendingPathComponent("projects/\(folder)")
        try sandbox.write("{\"a\":1}\n", to: source.appendingPathComponent("\(id).jsonl"))
        try sandbox.write("sub\n", to: source.appendingPathComponent("\(id)/subagents/agent-1.jsonl"))
        try sandbox.write("big\n", to: source.appendingPathComponent("\(id)/tool-results/x.txt"))
        // Another conversation of the same folder stays where it is.
        try sandbox.write("other\n", to: source.appendingPathComponent("other.jsonl"))
        try sandbox.mkdir(managedB)

        let transfer = ConversationTransfer(provider: .claude, conversationID: id, cwd: cwd, source: managedA, target: managedB)
        let report = try transfer.run()

        let target = managedB.appendingPathComponent("projects/\(folder)")
        #expect(report == .init(linked: 3, copied: 0, present: 0))
        #expect(try readText(target.appendingPathComponent("\(id).jsonl")) == "{\"a\":1}\n")
        #expect(try readText(target.appendingPathComponent("\(id)/subagents/agent-1.jsonl")) == "sub\n")
        #expect(try readText(target.appendingPathComponent("\(id)/tool-results/x.txt")) == "big\n")
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("other.jsonl").path))
        // The source is still there, and the target's folders are private.
        #expect(try readText(source.appendingPathComponent("\(id).jsonl")) == "{\"a\":1}\n")
        #expect(try posixMode(target) == 0o700)

        // Again (back and forth between accounts): already the same file, nothing changes.
        #expect(try transfer.run() == .init(linked: 0, copied: 0, present: 3))
        let back = ConversationTransfer(provider: .claude, conversationID: id, cwd: cwd, source: managedB, target: managedA)
        #expect(try back.run().present == 3)
    }

    @Test func claudeHistoryIsFoundThroughTheResolvedFolderOrAnyProject() throws {
        // `/tmp` is a link to `/private/tmp`; Claude files conversations under the resolved path.
        let link = sandbox.base.appendingPathComponent("link")
        let real = sandbox.base.appendingPathComponent("real")
        try sandbox.mkdir(real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let resolvedFolder = ConversationTransfer.claudeProjectFolder(forCwd: real.path)
        try sandbox.write("x\n", to: managedA.appendingPathComponent("projects/\(resolvedFolder)/\(id).jsonl"))
        try sandbox.mkdir(managedB)
        let steps = try ConversationTransfer(provider: .claude, conversationID: id, cwd: link.path, source: managedA,
                                             target: managedB).plan()
        #expect(steps.map(\.destination) == [managedB.appendingPathComponent("projects/\(resolvedFolder)/\(id).jsonl").path])

        // A conversation filed under another folder (the folder was renamed) is still found, and placed where Claude
        // looks for the session's folder now.
        let moved = Sandbox.uuidLike
        try sandbox.write("y\n", to: managedA.appendingPathComponent("projects/-old-name/\(moved).jsonl"))
        let movedSteps = try ConversationTransfer(provider: .claude, conversationID: moved, cwd: real.path, source: managedA,
                                                  target: managedB).plan()
        #expect(movedSteps.first?.source.hasSuffix("projects/-old-name/\(moved).jsonl") == true)
        #expect(movedSteps.first?.destination == managedB.appendingPathComponent("projects/\(resolvedFolder)/\(moved).jsonl").path)
    }

    // MARK: Codex

    @Test func codexRolloutKeepsItsDatedFolder() throws {
        let homeA = sandbox.dataRoot.appendingPathComponent("codex-homes/a/home")
        let homeB = sandbox.dataRoot.appendingPathComponent("codex-homes/b/home")
        let name = "rollout-2026-11-12T16-57-21-\(id).jsonl"
        try sandbox.write("{\"type\":\"session_meta\"}\n", to: homeA.appendingPathComponent("sessions/2026/11/12/\(name)"))
        try sandbox.write("older\n", to: homeA.appendingPathComponent("sessions/2026/10/01/rollout-2026-10-01T00-00-00-\(Sandbox.uuidLike).jsonl"))
        try sandbox.mkdir(homeB)

        let report = try ConversationTransfer(provider: .codex, conversationID: id, cwd: "/", source: homeA, target: homeB).run()

        #expect(report.linked == 1)
        let placed = homeB.appendingPathComponent("sessions/2026/11/12/\(name)")
        #expect(try readText(placed) == "{\"type\":\"session_meta\"}\n")
        #expect(!FileManager.default.fileExists(atPath: homeB.appendingPathComponent("sessions/2026/10").path))
        // No state database, config or login is written.
        #expect(try FileManager.default.contentsOfDirectory(atPath: homeB.path) == ["sessions"])
    }

    @Test func compressedCodexRolloutsAreFoundToo() throws {
        let homeA = sandbox.base.appendingPathComponent("a"), homeB = sandbox.base.appendingPathComponent("b")
        try sandbox.write("z", to: homeA.appendingPathComponent("sessions/2025/01/31/rollout-2025-01-31T10-00-00-\(id).jsonl.zst"))
        try sandbox.mkdir(homeB)
        let steps = try ConversationTransfer(provider: .codex, conversationID: id, cwd: "/", source: homeA, target: homeB).plan()
        #expect(steps.map(\.destination) == [homeB.appendingPathComponent("sessions/2025/01/31/rollout-2025-01-31T10-00-00-\(id).jsonl.zst").path])
    }

    // MARK: Never replacing

    @Test func aDifferentFileInTheTargetIsAConflictAndBothStay() throws {
        let homeA = sandbox.base.appendingPathComponent("a"), homeB = sandbox.base.appendingPathComponent("b")
        let relative = "sessions/2026/11/12/rollout-2026-11-12T16-57-21-\(id).jsonl"
        try sandbox.write("mine\n", to: homeA.appendingPathComponent(relative))
        try sandbox.write("theirs\n", to: homeB.appendingPathComponent(relative))
        let transfer = ConversationTransfer(provider: .codex, conversationID: id, cwd: "/", source: homeA, target: homeB)

        #expect(throws: ConversationTransferError.conflict(path: homeB.appendingPathComponent(relative).path)) { try transfer.plan() }
        #expect(throws: ConversationTransferError.self) { try transfer.run() }
        #expect(try readText(homeA.appendingPathComponent(relative)) == "mine\n")
        #expect(try readText(homeB.appendingPathComponent(relative)) == "theirs\n")
    }

    @Test func anIdenticalCopyInTheTargetCountsAsPlaced() throws {
        let homeA = sandbox.base.appendingPathComponent("a"), homeB = sandbox.base.appendingPathComponent("b")
        let relative = "sessions/2026/11/12/rollout-x-\(id).jsonl"
        try sandbox.write("same\n", to: homeA.appendingPathComponent(relative))
        try sandbox.write("same\n", to: homeB.appendingPathComponent(relative))
        let report = try ConversationTransfer(provider: .codex, conversationID: id, cwd: "/", source: homeA, target: homeB).run()
        #expect(report == .init(linked: 0, copied: 0, present: 1))
    }

    @Test func aCopyIsInstalledWithoutReplacingAnything() throws {
        let source = try sandbox.write("data\n", to: sandbox.base.appendingPathComponent("src.jsonl"))
        let destination = sandbox.base.appendingPathComponent("out/dst.jsonl").path
        // A file that appears at the destination meanwhile is kept when its content differs.
        try sandbox.write("other\n", to: URL(fileURLWithPath: destination))
        #expect(throws: ConversationTransferError.conflict(path: destination)) {
            try ConversationTransfer.place(.init(source: source.path, destination: destination))
        }
        #expect(try readText(URL(fileURLWithPath: destination)) == "other\n")
    }

    // MARK: Failures and limits

    @Test func missingHistoryOrTargetOrABadIDFailsBeforeWriting() throws {
        try sandbox.mkdir(managedA)
        try sandbox.mkdir(managedB)
        let missing = ConversationTransfer(provider: .claude, conversationID: id, cwd: "/w", source: managedA, target: managedB)
        #expect(throws: ConversationTransferError.historyNotFound) { try missing.run() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: managedB.path).isEmpty)

        let noTarget = ConversationTransfer(provider: .claude, conversationID: id, cwd: "/w", source: managedA,
                                            target: sandbox.base.appendingPathComponent("nowhere"))
        #expect(throws: ConversationTransferError.targetMissing) { try noTarget.plan() }

        for bad in ["", "../escape", "-rf", "a/b"] {
            let transfer = ConversationTransfer(provider: .codex, conversationID: bad, cwd: "/", source: managedA, target: managedB)
            #expect(throws: ConversationTransferError.invalidConversationID) { try transfer.plan() }
        }
    }

    /// The user's own login: only history files in the history folders, never settings, credentials or state.
    @Test func ownLoginTargetsGetHistoryFilesOnly() throws {
        let cwd = "/Users/someone/project"
        let folder = ConversationTransfer.claudeProjectFolder(forCwd: cwd)
        try sandbox.write("t\n", to: managedA.appendingPathComponent("projects/\(folder)/\(id).jsonl"))
        try sandbox.write("s\n", to: managedA.appendingPathComponent("projects/\(folder)/\(id)/subagents/a.jsonl"))
        try sandbox.write("{}", to: managedA.appendingPathComponent("settings.json"))
        try sandbox.write("{}", to: managedA.appendingPathComponent(".claude.json"))
        try sandbox.write("{}", to: sandbox.claudeHome.appendingPathComponent("settings.json"))

        let steps = try ConversationTransfer(provider: .claude, conversationID: id, cwd: cwd, source: managedA,
                                             target: sandbox.claudeHome).plan()
        let root = sandbox.claudeHome.appendingPathComponent("projects/\(folder)").path + "/"
        #expect(steps.count == 2)
        #expect(steps.allSatisfy { $0.destination.hasPrefix(root) })

        try ConversationTransfer(provider: .claude, conversationID: id, cwd: cwd, source: managedA, target: sandbox.claudeHome).run()
        let entries = try FileManager.default.subpathsOfDirectory(atPath: sandbox.claudeHome.path).sorted()
        #expect(entries == ["projects", "projects/\(folder)", "projects/\(folder)/\(id)", "projects/\(folder)/\(id).jsonl",
                            "projects/\(folder)/\(id)/subagents", "projects/\(folder)/\(id)/subagents/a.jsonl",
                            "settings.json"])
        #expect(try readText(sandbox.claudeHome.appendingPathComponent("settings.json")) == "{}")
    }

    @Test func destinationsOutsideTheHistoryFolderAreRefused() {
        let root = "/home/.claude/projects/-w"
        #expect(ConversationTransfer.isAllowed("/home/.claude/projects/-w/a.jsonl", root: root))
        #expect(ConversationTransfer.isAllowed("/home/.claude/projects/-w/a/subagents/b.jsonl", root: root))
        #expect(!ConversationTransfer.isAllowed("/home/.claude/projects/-w", root: root))
        #expect(!ConversationTransfer.isAllowed("/home/.claude/projects/-w/../../settings.json", root: root))
        #expect(!ConversationTransfer.isAllowed("/home/.claude/settings.json", root: root))
        #expect(!ConversationTransfer.isAllowed("/home/.claude/projects/-w/./a.jsonl", root: root))
        #expect(!ConversationTransfer.isAllowed("relative/a.jsonl", root: root))
    }

    @Test func linksInTheSourceFolderAreNotFollowed() throws {
        let cwd = "/w"
        let folder = ConversationTransfer.claudeProjectFolder(forCwd: cwd)
        let dir = managedA.appendingPathComponent("projects/\(folder)")
        try sandbox.write("t\n", to: dir.appendingPathComponent("\(id).jsonl"))
        try sandbox.write("secret", to: sandbox.base.appendingPathComponent("secret.txt"))
        try sandbox.mkdir(dir.appendingPathComponent(id))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("\(id)/leak.txt"),
                                                   withDestinationURL: sandbox.base.appendingPathComponent("secret.txt"))
        try sandbox.mkdir(managedB)
        let steps = try ConversationTransfer(provider: .claude, conversationID: id, cwd: cwd, source: managedA, target: managedB).plan()
        #expect(steps.count == 1)
    }
}

extension Sandbox {
    /// Another conversation id.
    static var uuidLike: String { UUID().uuidString.lowercased() }
}

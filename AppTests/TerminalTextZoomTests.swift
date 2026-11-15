import Foundation
import SuijinCore
import SuijinTerminal
import Testing
@testable import Suijin

/// The text size of one terminal (⌘+, ⌘-, ⌘0): an offset per session from the size in Settings, within the font
/// limits, kept across launches and dropped with the session.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct TerminalTextZoomTests {
    let root: URL
    let folder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-zoom-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func makeSessions(_ count: Int) async throws -> (AppModel, SessionContext, [UUID]) {
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspaceID = try #require(model.workspaces.first).id
        var ids: [UUID] = []
        for index in 0..<count {
            let record = AgentSessionRecord(workspaceID: workspaceID, worktreeID: nil, agent: .shell, accountID: nil,
                                            title: "s\(index)", cwd: folder.path, state: .exited)
            await model.upsert(record)
            ids.append(record.id)
        }
        return (model, .workspace(workspaceID), ids)
    }

    @Test func eachSessionKeepsItsOwnSizeAroundTheSizeInSettings() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, ids) = try await makeSessions(2)
        let base = Double(TerminalTheme.defaultFontSize)
        #expect(model.terminalFontSize(of: ids[0]) == base)

        // The keys typed in the first session's terminal change that session only.
        #expect(model.handle(.biggerText, in: context, from: ids[0]))
        #expect(model.handle(.biggerText, in: context, from: ids[0]))
        #expect(model.terminalFontSize(of: ids[0]) == base + 2)
        #expect(model.terminalFontSize(of: ids[1]) == base)
        #expect(model.handle(.smallerText, in: context, from: ids[1]))
        #expect(model.terminalFontSize(of: ids[1]) == base - 1)
        #expect(model.terminalFontSize(of: ids[0]) == base + 2)

        // A new size in Settings moves both; each keeps its distance from it.
        model.setSetting(.terminalFontSize, "16")
        #expect(model.terminalFontSize(of: ids[0]) == 18)
        #expect(model.terminalFontSize(of: ids[1]) == 15)

        // ⌘0 is the size in Settings again, and nothing is kept for the session.
        #expect(model.handle(.defaultTextSize, in: context, from: ids[0]))
        #expect(model.terminalFontSize(of: ids[0]) == 16)
        #expect(model.terminalFontOffsets[ids[0]] == nil)
        model.resetTerminalFontSize(of: ids[1])
        #expect(model.terminalFontOffsets[ids[1]] == nil)
    }

    @Test func theSizeStopsAtTheFontLimitsAndComesBackWithOneStep() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, ids) = try await makeSessions(1)
        let largest = Double(TerminalTheme.maximumFontSize), smallest = Double(TerminalTheme.minimumFontSize)
        for _ in 0..<60 { model.adjustTerminalFontSize(of: ids[0], by: 1) }
        #expect(model.terminalFontSize(of: ids[0]) == largest)
        model.adjustTerminalFontSize(of: ids[0], by: -1)
        #expect(model.terminalFontSize(of: ids[0]) == largest - 1)
        for _ in 0..<60 { model.adjustTerminalFontSize(of: ids[0], by: -1) }
        #expect(model.terminalFontSize(of: ids[0]) == smallest)
        model.adjustTerminalFontSize(of: ids[0], by: 1)
        #expect(model.terminalFontSize(of: ids[0]) == smallest + 1)

        // A size in Settings that leaves the offset no room: the limit holds, and one step back still shows.
        model.setSetting(.terminalFontSize, String(Int(largest)))
        #expect(model.terminalFontSize(of: ids[0]) == smallest + 1 + (largest - Double(TerminalTheme.defaultFontSize)))
        model.resetTerminalFontSize(of: ids[0])
        model.adjustTerminalFontSize(of: ids[0], by: 1)
        #expect(model.terminalFontSize(of: ids[0]) == largest)
        #expect(model.terminalFontOffsets[ids[0]] == nil)
        model.resetTerminalFontSize(of: ids[0])
    }

    @Test func theSizeSurvivesARelaunchAndGoesWithAClosedSession() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, ids) = try await makeSessions(2)
        model.adjustTerminalFontSize(of: ids[0], by: 3)
        model.adjustTerminalFontSize(of: ids[1], by: -2)
        // What the next launch reads.
        #expect(AppModel.savedTerminalFontOffsets()[ids[0]] == 3)
        #expect(AppModel.savedTerminalFontOffsets()[ids[1]] == -2)

        await model.closeSession(ids[0])
        #expect(model.terminalFontOffsets[ids[0]] == nil)
        #expect(AppModel.savedTerminalFontOffsets()[ids[0]] == nil)
        #expect(AppModel.savedTerminalFontOffsets()[ids[1]] == -2)
        await model.closeSession(ids[1])
        #expect(AppModel.savedTerminalFontOffsets()[ids[1]] == nil)
    }
}

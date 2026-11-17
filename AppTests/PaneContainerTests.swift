import AppKit
import Foundation
import SuijinCore
import SuijinTerminal
import SwiftUI
import Testing
@testable import Suijin

/// The split tab's container: native split views sized by the layout, minimum pane sizes, double-click to share a
/// split equally, and the pane shortcuts a terminal routes to the model.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PaneContainerTests {
    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    @Test func childrenUnderTheirMinimumTakeRoomFromTheOthers() {
        let lengths = PaneSplitContainer.lengths(shares: [0.5, 0.25, 0.125, 0.0625, 0.0625], minimums: Array(repeating: 160, count: 5),
                                                 total: 1000)
        #expect(lengths.allSatisfy { $0 >= 160 - 0.001 })
        #expect(abs(lengths.reduce(0, +) - 1000) < 0.001)
        #expect(lengths[0] > lengths[1])
        // When even the minimums do not fit, the shares stand.
        #expect(PaneSplitContainer.lengths(shares: [0.5, 0.5], minimums: [400, 400], total: 600) == [300, 300])
    }

    private func makeSplitTab() async throws -> (AppModel, SessionContext, PaneLayout, NSWindow, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-container-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspaceID = try #require(model.workspaces.first).id
        let context = SessionContext.workspace(workspaceID)
        var ids: [UUID] = []
        for index in 0..<3 {
            // Records only: each pane shows its ended view, which is enough to lay the container out.
            let record = AgentSessionRecord(workspaceID: workspaceID, worktreeID: nil, agent: .shell, accountID: nil,
                                            title: "s\(index)", cwd: folder.path, state: .exited)
            await model.upsert(record)
            ids.append(record.id)
        }
        try model.insertPane(ids[1], beside: ids[0], edge: .right)
        try model.insertPane(ids[2], beside: ids[1], edge: .right)
        let layout = try #require(model.layout(containing: ids[0]))
        model.setPaneFractions([0.5, 0.3, 0.2], at: [], in: layout.id)

        let window = OffscreenWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SessionTabsView(context: context).environment(model))
        window.orderFrontRegardless()
        return (model, context, try #require(model.paneLayouts[layout.id]), window, root)
    }

    private func splitView(in view: NSView) -> PaneSplitContainer? {
        if let split = view as? PaneSplitContainer { return split }
        for child in view.subviews { if let found = splitView(in: child) { return found } }
        return nil
    }

    private func widths(_ split: PaneSplitContainer) -> [Double] {
        let total = split.arrangedSubviews.reduce(0) { $0 + $1.frame.width }
        return split.arrangedSubviews.map { Double($0.frame.width / total) }
    }

    @Test func splitFollowsTheLayoutThroughResizesAndADoubleClickEqualizes() async throws {
        let (model, _, layout, window, root) = try await makeSplitTab()
        defer {
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: root)
        }
        let content = try #require(window.contentView)
        #expect(await eventually { splitView(in: content)?.arrangedSubviews.count == 3 })
        let split = try #require(splitView(in: content))
        #expect(split.isVertical)
        #expect(await eventually { zip(widths(split), [0.5, 0.3, 0.2]).allSatisfy { abs($0 - $1) < 0.01 } })

        // A window resize keeps every share.
        window.setContentSize(NSSize(width: 900, height: 600))
        try await Task.sleep(for: .milliseconds(200))
        #expect(zip(widths(split), [0.5, 0.3, 0.2]).allSatisfy { abs($0 - $1) < 0.01 }, "\(widths(split))")

        // A double-click on the first divider shares the split equally, in the model too.
        let dividerX = split.arrangedSubviews[0].frame.maxX + split.dividerThickness / 2
        let point = split.convert(NSPoint(x: dividerX, y: split.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 2, pressure: 1))
        split.mouseDown(with: event)
        let shares = try #require(model.paneLayouts[layout.id]?.split(at: [])?.fractions)
        #expect(shares.allSatisfy { abs($0 - 1.0 / 3) < 0.01 }, "\(shares)")
        #expect(await eventually { widths(split).allSatisfy { abs($0 - 1.0 / 3) < 0.01 } })

        // Every pane keeps the minimum size even in a narrow window.
        window.setContentSize(NSSize(width: 560, height: 400))
        try await Task.sleep(for: .milliseconds(200))
        #expect(split.arrangedSubviews.allSatisfy { $0.frame.width >= PaneCell.minimumSize.width - 1 })
    }

    @Test func paneShortcutsFromATerminalActOnItsTab() async throws {
        let (model, context, layout, window, root) = try await makeSplitTab()
        defer {
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: root)
        }
        let panes = layout.panes
        #expect(model.handle(.focusPane(.left), in: context, from: panes[2]))
        #expect(model.activeSession(in: context) == panes[1])
        #expect(model.handle(.zoomPane, in: context, from: panes[1]))
        #expect(model.visiblePanes(in: context) == [panes[1]])
        #expect(model.handle(.zoomPane, in: context, from: panes[1]))
        #expect(model.visiblePanes(in: context) == panes)
        #expect(model.handle(.equalizePanes, in: context, from: panes[0]))
        #expect(model.paneLayouts[layout.id]?.split(at: [])?.fractions.allSatisfy { abs($0 - 1.0 / 3) < 1e-9 } == true)
    }
}

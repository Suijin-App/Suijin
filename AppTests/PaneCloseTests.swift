import AppKit
import Foundation
import SuijinCore
import SuijinTerminal
import SwiftUI
import Testing
@testable import Suijin

/// ⌘W in a split tab closes the pane that has the keyboard, whichever way the pane got it: a click, the app focusing
/// it, or AppKit moving the first responder on its own. Runs the real tab view with real shells in the PTY host.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PaneCloseTests {
    /// A split tab on screen: the window, its two sessions and their terminal views.
    @MainActor
    struct Fixture {
        let model: AppModel
        let context: SessionContext
        let window: NSWindow
        let root: URL
        let primary: UUID
        let secondary: UUID
        let primaryView: SuijinTerminalView
        let secondaryView: SuijinTerminalView

        func tearDown() async {
            window.orderOut(nil)
            for session in model.sessions { await model.closeSession(session.id) }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    private func makeSplitTab() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-pane-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.selection = context
        await model.runtimes.bootstrap()
        let primary = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))

        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SessionTabsView(context: context).environment(model))
        window.orderFrontRegardless()
        let primaryView = try #require(model.runtimes.runtime(for: primary)).terminal.view
        #expect(await eventually { window.firstResponder === primaryView })

        model.split(in: context, axis: .sideBySide)
        #expect(await eventually { model.sessions.count == 2 })
        let secondary = try #require(model.sessions.first { $0.id != primary }?.id)
        let secondaryView = try #require(model.runtimes.runtime(for: secondary)).terminal.view
        // The new pane takes the keyboard.
        #expect(await eventually { window.firstResponder === secondaryView })
        #expect(model.activeSession(in: context) == secondary)
        return Fixture(model: model, context: context, window: window, root: root, primary: primary, secondary: secondary,
                       primaryView: primaryView, secondaryView: secondaryView)
    }

    /// A click through the event queue, so the app's local event monitors see it as they see a real one.
    private func click(_ view: NSView, in window: NSWindow) async throws {
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(400))
    }

    /// The keyboard moved to the first pane without a click (`FocusingContainer`, `focusActiveTerminalAfterClick` and
    /// AppKit itself call `makeFirstResponder`), while the model still marked the new second pane as focused: ⌘W typed
    /// in the first pane closed the second one.
    @Test func commandWTypedInAPaneClosesThatPane() async throws {
        let fixture = try await makeSplitTab()
        let model = fixture.model

        fixture.window.makeFirstResponder(fixture.primaryView)
        try await Task.sleep(for: .milliseconds(200))
        // ⌘W reaches the terminal with the keyboard through its key route.
        #expect(fixture.primaryView.perform(.closeTab))
        #expect(await eventually { model.sessions.count == 1 })
        #expect(model.sessions.map(\.id) == [fixture.secondary], "⌘W closed a pane other than the one it was typed in")
        await fixture.tearDown()
    }

    /// The same through the Close Tab menu command (⌘W when no terminal has the keyboard handles it).
    @Test func closeCommandFollowsTheKeyboardWhenItMovesWithoutAClick() async throws {
        let fixture = try await makeSplitTab()
        let model = fixture.model

        fixture.window.makeFirstResponder(fixture.primaryView)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.activeSession(in: fixture.context) == fixture.primary)
        model.closeActive(in: fixture.context)
        #expect(await eventually { model.sessions.count == 1 })
        #expect(model.sessions.map(\.id) == [fixture.secondary], "Close Tab closed a pane other than the one with the keyboard")
        await fixture.tearDown()
    }

    /// Clicks on either pane: whatever the click did with the keyboard, the model agrees with it and ⌘W closes the pane
    /// with the keyboard. The pane left stays on screen with the keyboard: its terminal used to stay behind in the
    /// split's discarded container, so the tab went blank and the next ⌘W (now handled by the menu) closed it too.
    @Test func afterAClickCommandWClosesThePaneWithTheKeyboard() async throws {
        let fixture = try await makeSplitTab()
        let model = fixture.model
        let views = [fixture.primary: fixture.primaryView, fixture.secondary: fixture.secondaryView]

        for target in [fixture.primaryView, fixture.secondaryView, fixture.primaryView] {
            try await click(target, in: fixture.window)
            let focused = views.first { $0.value === fixture.window.firstResponder }?.key
            #expect(focused != nil)
            #expect(model.activeSession(in: fixture.context) == focused, "the model's focused pane is not the one with the keyboard")
        }
        let focused = try #require(views.first { $0.value === fixture.window.firstResponder })
        let other = focused.key == fixture.primary ? fixture.secondary : fixture.primary
        #expect(focused.value.perform(.closeTab))
        #expect(await eventually { model.sessions.count == 1 })
        #expect(model.sessions.map(\.id) == [other])
        #expect(model.tabSessions(in: fixture.context).map(\.id) == [other])
        let gotBack = await eventually { fixture.window.firstResponder === views[other] }
        #expect(views[other]?.window === fixture.window, "the pane left is not on screen")
        #expect(gotBack, "the pane left did not get the keyboard back")
        await fixture.tearDown()
    }
}

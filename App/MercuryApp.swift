import AppKit
import MercuryCore
import MercuryUI
import SwiftUI
import UserNotifications

/// Picks the app to run: Mercury itself, or a bare host for the tests XCTest injects (no window, no user data).
@main
enum MercuryMain {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            TestHostApp.main()
        } else {
            #if DEBUG
            // Screenshot runs force an appearance: `-MercuryAppearance dark|light`.
            if let forced = UserDefaults.standard.string(forKey: "MercuryAppearance") {
                NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { NSApp.appearance = NSAppearance(named: forced == "dark" ? .darkAqua : .aqua) }
                }
            }
            #endif
            MercuryApp.main()
        }
    }
}

struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct MercuryApp: App {
    @NSApplicationDelegateAdaptor private var delegate: MercuryAppDelegate
    @State private var model = AppModel.live()

    var body: some Scene {
        Window("Mercury", id: "main") {
            RootView()
                .environment(model)
                .task {
                    delegate.model = model
                    await model.loadSettings()
                    model.applyAppearance()
                    await model.load()
                    await model.runtimes.bootstrap()
                    #if DEBUG
                    await model.openDemoPanesIfRequested()
                    #endif
                    #if DEBUG || MERCURY_PERF
                    PerfProbe.startIfRequested(model: model)
                    #endif
                    await HelperVersionCheck.run()
                    UpdaterController.shared.start()
                    await model.accountsController.removeAbandonedHomes()
                    await model.accountsController.writePointers()
                    model.accountsController.startPolling()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            MercuryCommands(model: model)
            UpdateCommands()
        }

        Window("Design Gallery", id: "design-gallery") {
            DesignGalleryView()
        }
        .keyboardShortcut("g", modifiers: [.command, .option, .shift])
        .defaultSize(width: 860, height: 640)
    }
}

/// Quitting detaches from hosted sessions (they keep running in the PTY host) or ends them, as Settings say.
/// Also the notification delegate: banners show while Mercury is in front (the user is looking at another tab), and
/// clicking one opens that session.
@MainActor
final class MercuryAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel?
    private var isShuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["session"] as? String, let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            guard let model, let record = model.sessions.first(where: { $0.id == id }) else { return }
            let context = model.context(of: record)
            model.selection = context
            model.selectedTab[context] = .session(id)
            NSApp.activate()
            model.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateLater }
        isShuttingDown = true
        Task { @MainActor in
            await model?.runtimes.prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Menu commands: ⌘N new worktree, ⌘T new session, ⌘W close tab (or pane), ⇧⌘O add workspace, pane commands in the
/// Session menu. ⌘, shows or hides Settings over the main window.
struct MercuryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // Settings open over the main window rather than in a window of their own.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                withAnimation(.easeOut(duration: 0.18)) { model.settingsPage = model.settingsPage == nil ? .general : nil }
                NSApp.activate()
                model.mainWindow?.makeKeyAndOrderFront(nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Worktree…") {
                if let context = mainContext, let id = model.workspaceID(of: context), model.workspace(id)?.kind == .git {
                    model.newWorktreeWorkspaceID = id
                }
            }
            .keyboardShortcut("n")
            Button("New Session") { if let context = mainContext { model.newTab(in: context) } }
                .keyboardShortcut("t")
            Button("New Shell") { if let context = mainContext { model.newTab(in: context, agent: .shell) } }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            Button("Add Workspace…") { AddWorkspaceFlow.run(model: model) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            // ⌘W acts on sessions only in the main window (closing Settings first when they show); anywhere else
            // (the gallery) it closes that window.
            // In a split tab ⌘W closes the focused pane only, and says so.
            Button(isSplitTab ? "Close Pane" : "Close Tab") {
                if model.settingsPage != nil {
                    withAnimation(.easeOut(duration: 0.18)) { model.settingsPage = nil }
                    return
                }
                model.performCloseCommand()
            }
            .keyboardShortcut("w")
        }
        CommandMenu("Session") {
            Button("Split Right") { if let context = mainContext { model.split(in: context, axis: .sideBySide) } }
                .keyboardShortcut("d")
            Button("Split Down") { if let context = mainContext { model.split(in: context, axis: .stacked) } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button(isZoomed ? "Show All Panes" : "Zoom Pane") { if let pane = focusedPane { model.toggleZoom(pane) } }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!isSplitTab)
            Button("Equalize Panes") { if let pane = focusedPane, let layout = model.layout(containing: pane) { model.equalizePanes(layout.id) } }
                .keyboardShortcut("=", modifiers: [.command, .control])
                .disabled(!isSplitTab)
            Menu("Focus Pane") {
                focusItem("Left", edge: .left, key: .leftArrow)
                focusItem("Right", edge: .right, key: .rightArrow)
                focusItem("Above", edge: .top, key: .upArrow)
                focusItem("Below", edge: .bottom, key: .downArrow)
            }
            .disabled(!isSplitTab)
            // Swaps the focused pane with its neighbor; the same as ⌃⌥⌘ arrows typed in a terminal.
            Menu("Move Pane") {
                moveItem("Left", edge: .left, key: .leftArrow)
                moveItem("Right", edge: .right, key: .rightArrow)
                moveItem("Up", edge: .top, key: .upArrow)
                moveItem("Down", edge: .bottom, key: .downArrow)
            }
            .disabled(!isSplitTab || isZoomed)
            Divider()
            Button("Previous Tab") { if let context = mainContext { model.selectAdjacentTab(in: context, offset: -1) } }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { if let context = mainContext { model.selectAdjacentTab(in: context, offset: 1) } }
                .keyboardShortcut("]", modifiers: [.command, .shift])
        }
    }

    /// The selected context, only while the main window is the key window.
    private var mainContext: SessionContext? {
        model.isMainWindowKey ? model.selection : nil
    }

    /// The focused pane of the selected tab, when that tab is a split tab.
    private var focusedPane: UUID? {
        guard let context = mainContext, case .panes? = model.currentTab(in: context) else { return nil }
        return model.activeSession(in: context)
    }

    private var isSplitTab: Bool { focusedPane != nil }

    private var isZoomed: Bool {
        guard let pane = focusedPane else { return false }
        return model.layout(containing: pane)?.zoomed != nil
    }

    private func focusItem(_ title: LocalizedStringKey, edge: PaneEdge, key: KeyEquivalent) -> some View {
        Button(title) { if let context = mainContext { model.focusNeighborPane(in: context, toward: edge) } }
            .keyboardShortcut(key, modifiers: [.command, .option])
    }

    private func moveItem(_ title: LocalizedStringKey, edge: PaneEdge, key: KeyEquivalent) -> some View {
        Button(title) { if let context = mainContext { model.moveFocusedPane(in: context, toward: edge) } }
            .keyboardShortcut(key, modifiers: [.command, .option, .control])
    }
}

import AppKit
import SevindaCore
import SevindaUI
import SwiftUI
import UserNotifications

/// Picks the app to run: Sevinda itself, or a bare host for the tests XCTest injects (no window, no user data).
@main
enum SevindaMain {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            TestHostApp.main()
        } else {
            #if DEBUG
            // Screenshot runs force an appearance: `-SevindaAppearance dark|light`.
            if let forced = UserDefaults.standard.string(forKey: "SevindaAppearance") {
                NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { NSApp.appearance = NSAppearance(named: forced == "dark" ? .darkAqua : .aqua) }
                }
            }
            #endif
            SevindaApp.main()
        }
    }
}

struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct SevindaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: SevindaAppDelegate
    @State private var model = AppModel.live()

    var body: some Scene {
        Window("Sevinda", id: "main") {
            RootView()
                .environment(model)
                .task {
                    delegate.model = model
                    await model.loadSettings()
                    model.applyAppearance()
                    await model.load()
                    model.showOnboardingIfNeeded()
                    await model.runtimes.bootstrap()
                    #if DEBUG
                    await model.openDemoPanesIfRequested()
                    #endif
                    #if DEBUG || SEVINDA_PERF
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
            SevindaCommands(model: model)
            UpdateCommands()
        }

        Window("Design Gallery", id: "design-gallery") {
            DesignGalleryView()
        }
        .keyboardShortcut(ShortcutCatalog.designGallery.shortcut)
        .defaultSize(width: 860, height: 640)
    }
}

/// Quitting detaches from hosted sessions (they keep running in the PTY host) or ends them, as Settings say.
/// Also the notification delegate: banners show while Sevinda is in front (the user is looking at another tab), and
/// clicking one opens that session.
@MainActor
final class SevindaAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel?
    private var isShuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Back in Sevinda, the window shows every session's state, so the banners posted while it was in the background
    /// are cleared from Notification Center.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !UserNotifier.isTestHost else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// A notification that arrives while Sevinda is in front (posted just before the user switched back) stays out of
    /// the way: no banner or sound over the window the user is working in.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        []
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
/// Session menu. ⌘, shows or hides Settings over the main window; Help › Welcome to Sevinda opens the welcome tour and
/// Help › Keyboard Shortcuts the Shortcuts settings. Every shortcut comes from `ShortcutCatalog`.
struct SevindaCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // Settings open over the main window rather than in a window of their own.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { showSettings(model.settingsPage == nil ? .general : nil) }
                .keyboardShortcut(ShortcutCatalog.settings.shortcut)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Worktree…") {
                if let context = mainContext, let id = model.workspaceID(of: context), model.workspace(id)?.kind == .git {
                    model.newWorktreeWorkspaceID = id
                }
            }
            .keyboardShortcut(ShortcutCatalog.newWorktree.shortcut)
            Button("New Session") { if let context = mainContext { model.newTab(in: context) } }
                .keyboardShortcut(ShortcutCatalog.newSession.shortcut)
            Button("New Shell") { if let context = mainContext { model.newTab(in: context, agent: .shell) } }
                .keyboardShortcut(ShortcutCatalog.newShell.shortcut)
            Divider()
            Button("Add Workspace…") { AddWorkspaceFlow.run(model: model) }
                .keyboardShortcut(ShortcutCatalog.addWorkspace.shortcut)
        }
        CommandGroup(replacing: .saveItem) {
            // ⌘W acts on sessions only in the main window (closing the welcome tour or Settings first when they
            // show); anywhere else (the gallery) it closes that window.
            // In a split tab ⌘W closes the focused pane only, and says so.
            Button(isSplitTab ? "Close Pane" : "Close Tab") {
                if model.onboarding != nil {
                    withAnimation(.easeOut(duration: 0.2)) { model.finishOnboarding() }
                    return
                }
                if model.settingsPage != nil {
                    withAnimation(.easeOut(duration: 0.18)) { model.settingsPage = nil }
                    return
                }
                model.performCloseCommand()
            }
            .keyboardShortcut(ShortcutCatalog.closeTab.shortcut)
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Sevinda") {
                withAnimation(.easeOut(duration: 0.2)) { model.showOnboarding() }
                NSApp.activate()
                model.mainWindow?.makeKeyAndOrderFront(nil)
            }
            Button("Keyboard Shortcuts") { showSettings(.shortcuts) }
                .keyboardShortcut(ShortcutCatalog.keyboardShortcuts.shortcut)
        }
        CommandMenu("Session") {
            Button("Split Right") { if let context = mainContext { model.split(in: context, axis: .sideBySide) } }
                .keyboardShortcut(ShortcutCatalog.splitRight.shortcut)
            Button("Split Down") { if let context = mainContext { model.split(in: context, axis: .stacked) } }
                .keyboardShortcut(ShortcutCatalog.splitDown.shortcut)
            Divider()
            Button(isZoomed ? "Show All Panes" : "Zoom Pane") { if let pane = focusedPane { model.toggleZoom(pane) } }
                .keyboardShortcut(ShortcutCatalog.zoomPane.shortcut)
                .disabled(!isSplitTab)
            Button("Equalize Panes") { if let pane = focusedPane, let layout = model.layout(containing: pane) { model.equalizePanes(layout.id) } }
                .keyboardShortcut(ShortcutCatalog.equalizePanes.shortcut)
                .disabled(!isSplitTab)
            Menu("Focus Pane") {
                focusItem("Left", edge: .left)
                focusItem("Right", edge: .right)
                focusItem("Above", edge: .top)
                focusItem("Below", edge: .bottom)
            }
            .disabled(!isSplitTab)
            // Swaps the focused pane with its neighbor; the same as ⌃⌥⌘ arrows typed in a terminal.
            Menu("Move Pane") {
                moveItem("Left", edge: .left)
                moveItem("Right", edge: .right)
                moveItem("Up", edge: .top)
                moveItem("Down", edge: .bottom)
            }
            .disabled(!isSplitTab || isZoomed)
            Divider()
            Button("Previous Tab") { if let context = mainContext { model.selectAdjacentTab(in: context, offset: -1) } }
                .keyboardShortcut(ShortcutCatalog.previousTab.shortcut)
            Button("Next Tab") { if let context = mainContext { model.selectAdjacentTab(in: context, offset: 1) } }
                .keyboardShortcut(ShortcutCatalog.nextTab.shortcut)
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

    private func focusItem(_ title: LocalizedStringKey, edge: PaneEdge) -> some View {
        Button(title) { if let context = mainContext { model.focusNeighborPane(in: context, toward: edge) } }
            .keyboardShortcut(ShortcutCatalog.focusPane(edge).shortcut)
    }

    private func moveItem(_ title: LocalizedStringKey, edge: PaneEdge) -> some View {
        Button(title) { if let context = mainContext { model.moveFocusedPane(in: context, toward: edge) } }
            .keyboardShortcut(ShortcutCatalog.movePane(edge).shortcut)
    }

    /// Shows Settings on `page` over the main window (`nil` hides them). Settings replace the welcome tour rather
    /// than opening under it.
    private func showSettings(_ page: SettingsPage?) {
        withAnimation(.easeOut(duration: 0.18)) {
            if model.onboarding != nil { model.finishOnboarding() }
            model.settingsPage = page
        }
        NSApp.activate()
        model.mainWindow?.makeKeyAndOrderFront(nil)
    }
}

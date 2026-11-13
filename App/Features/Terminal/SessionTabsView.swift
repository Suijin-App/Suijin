import SuijinCore
import SuijinUI
import SwiftUI

/// The detail area of a context: a tab per session plus a Changes tab (git contexts), and the selected tab's
/// content. Custom tab strip on purpose: SwiftUI on macOS has no in-content document tab bar (`TabView` draws a
/// segmented control without close buttons or status).
struct SessionTabsView: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext

    var body: some View {
        let selected = model.currentTab(in: context)
        VStack(spacing: 0) {
            Group {
                switch selected {
                case .session(let id):
                    SessionPaneContent(session: id, context: context, isFocused: true, closeTitle: "Close Tab")
                case .panes(let id):
                    if let layout = model.paneLayouts[id] {
                        PaneTreeView(layout: layout, context: context)
                    }
                case .changes:
                    DiffScreen(context: context)
                case .file(let path):
                    FileViewer(path: path, context: context).id(path)
                case nil:
                    NoSessionView(context: context)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// What a session's place in a tab or pane shows.
enum SessionPaneState: Hashable {
    /// The live terminal.
    case terminal
    /// Not ready yet: a session that kept running is being attached again or replays its scrollback, or launch has
    /// not found out yet whether its process still runs.
    case reconnecting
    /// An ended agent is being resumed: from the click until it runs, then while it re-prints its conversation behind
    /// the progress view (`TerminalSession.catchUp`).
    case resuming
    /// The process is gone.
    case ended
    /// No such session.
    case missing
}

extension AppModel {
    func paneState(of session: UUID) -> SessionPaneState {
        // A conversation moving to another account covers the session from the click, while the old agent still ends.
        if runtimes.movingConversation[session] != nil, sessions.contains(where: { $0.id == session }) { return .resuming }
        if runtimes.runtime(for: session) != nil {
            if runtimes.reconnecting.contains(session) { return .reconnecting }
            return runtimes.catchingUp.contains(session) ? .resuming : .terminal
        }
        guard let record = sessions.first(where: { $0.id == session }) else { return .missing }
        if runtimes.resuming.contains(session) { return .resuming }
        // Until launch has attached the sessions that kept running, a live record is not ended, only not back yet. A
        // record already ended shows the ended view at once: its process is never attached again.
        if runtimes.isRestoring, record.state != .exited, record.state != .failed { return .reconnecting }
        return .ended
    }
}

/// A session's place in a tab or pane: its live terminal, the reconnecting view until a session that kept running is
/// attached again (or the resuming view while a resumed agent re-prints its conversation), or the ended view once its
/// process is gone.
struct SessionPaneContent: View {
    @Environment(AppModel.self) private var model
    let session: UUID
    let context: SessionContext
    let isFocused: Bool
    /// The ended view's close button: "Close Tab" in a plain tab, "Close Pane" in a split tab.
    let closeTitle: LocalizedStringKey

    var body: some View {
        let state = model.paneState(of: session)
        if let runtime = model.runtimes.runtime(for: session) {
            // The terminal stays in place under the progress views (hidden meanwhile), so it keeps its size and focus.
            TerminalPane(runtime: runtime, context: context, isFocused: isFocused)
                .id(session)
                .overlay {
                    switch state {
                    case .reconnecting: SessionProgressView(title: "Reconnecting to session…")
                    case .resuming: resumingView
                    case .terminal, .ended, .missing: EmptyView()
                    }
                }
                .overlay(alignment: .top) {
                    if state == .terminal, let record = model.sessions.first(where: { $0.id == session }), record.agent != .shell {
                        VStack(spacing: 0) {
                            AutoSwitchNoteView(session: session)
                            UsageLimitBanner(session: record)
                        }
                    }
                }
        } else if let record = model.sessions.first(where: { $0.id == session }) {
            switch state {
            case .reconnecting: SessionProgressView(title: "Reconnecting to session…")
            case .resuming: resumingView
            case .terminal, .ended, .missing: EndedSessionView(record: record, closeTitle: closeTitle)
            }
        }
    }

    /// "Moving conversation to …" while the conversation changes account, "Resuming session…" otherwise.
    @ViewBuilder private var resumingView: some View {
        if let target = model.runtimes.movingConversation[session] {
            SessionProgressView(title: "Moving conversation to \(target)…")
        } else {
            SessionProgressView(title: "Resuming session…")
        }
    }
}

/// The tabs of a context in the window's title bar, like Safari's compact tabs: one rounded group centered in the
/// toolbar that grows with the tabs (a single tab is a compact pill, each tab adds room) up to the toolbar's width.
/// Once every tab cannot get `minimumTabWidth`, the group scrolls sideways with fixed-width tabs and keeps the
/// selected tab in view. Custom on purpose: SwiftUI on macOS has no document tab bar with close buttons and status
/// (`TabView` draws a segmented control).
struct ToolbarTabBar: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext

    static let minimumTabWidth: CGFloat = 150
    /// Room each tab asks for, and the width of the group with one tab (Safari's compact address field).
    static let preferredTabWidth: CGFloat = 260
    static let singleTabWidth: CGFloat = 420

    var body: some View {
        let tabs = model.tabList(in: context)
        let selected = model.currentTab(in: context)
        GeometryReader { proxy in
            let groupWidth = min(proxy.size.width, max(Self.singleTabWidth, CGFloat(tabs.count) * Self.preferredTabWidth))
            let inner = groupWidth - 6
            let fits = CGFloat(max(tabs.count, 1)) * Self.minimumTabWidth + CGFloat(max(tabs.count - 1, 0)) * 2 <= inner
            Group {
                if fits {
                    HStack(spacing: 2) { tabViews(tabs, selected: selected, width: nil) }
                } else {
                    ScrollViewReader { reader in
                        ScrollView(.horizontal) {
                            HStack(spacing: 2) { tabViews(tabs, selected: selected, width: Self.minimumTabWidth) }
                        }
                        .scrollIndicators(.never)
                        // After the first layout pass; scrolling during it has no effect.
                        .task { reader.scrollTo(selected, anchor: .center) }
                        .onChange(of: selected) { _, tab in
                            withAnimation(.snappy) { reader.scrollTo(tab, anchor: .center) }
                        }
                    }
                }
            }
            .padding(3)
            .frame(width: groupWidth, height: proxy.size.height)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .clipShape(Capsule())
            .modifier(PaneTabBarDropTarget(context: context))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Never wider than the tabs ask for, so the toolbar keeps room for its buttons instead of moving them into
        // the overflow menu.
        .frame(minWidth: 240, idealWidth: targetWidth(tabs.count), maxWidth: targetWidth(tabs.count))
        .frame(height: 32)
        .animation(.snappy(duration: 0.22), value: tabs)
    }

    /// What the tabs ask for, limited to the detail column minus the toolbar's buttons so none of them moves into the
    /// overflow menu.
    private func targetWidth(_ count: Int) -> CGFloat {
        let wanted = max(Self.singleTabWidth, CGFloat(count) * Self.preferredTabWidth)
        return max(240, min(wanted, model.detailWidth - reservedToolbarWidth))
    }

    /// Room the buttons beside the tabs take: the agent menu, new session, split pane and the inspector toggle, each
    /// in its own glass, plus commit, push, pull request and new worktree in a git context.
    private var reservedToolbarWidth: CGFloat {
        let isGit = model.workspaceID(of: context).flatMap(model.workspace)?.kind == .git
        return isGit ? 500 : 320
    }

    @ViewBuilder
    private func tabViews(_ tabs: [DetailTab], selected: DetailTab?, width: CGFloat?) -> some View {
        if tabs.isEmpty {
            Text("No Sessions").foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        ForEach(tabs, id: \.self) { tab in
            Group {
                switch tab {
                case .session, .panes:
                    // A split tab reads as its focused pane, with the number of panes beside it.
                    let shown = model.panes(of: tab)
                    let focused = if case .panes(let id) = tab { model.paneLayouts[id]?.focused } else { shown.first }
                    if let session = model.sessions.first(where: { $0.id == focused }) {
                        SessionTab(session: session, paneCount: shown.count, isSelected: selected == tab) {
                            model.selectedTab[context] = tab
                        } onClose: {
                            model.requestCloseTab(tab)
                        }
                    }
                case .changes:
                    ToolbarTab(isSelected: selected == .changes, onClose: nil) {
                        model.selectedTab[context] = .changes
                    } label: {
                        Image(systemName: "plusminus").foregroundStyle(.secondary)
                        Text("Changes")
                    }
                case .file(let path):
                    ToolbarTab(isSelected: selected == tab, onClose: { model.closeFile(path, in: context) }) {
                        model.selectedTab[context] = tab
                    } label: {
                        Image(nsImage: FileIcons.icon(forPath: path)).resizable().frame(width: 14, height: 14)
                        Text(verbatim: (path as NSString).lastPathComponent)
                    }
                    .help(Text(verbatim: (path as NSString).abbreviatingWithTildeInPath))
                }
            }
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .modifier(TabReordering(tab: tab, context: context))
            .id(tab)
        }
    }
}

/// Drag any tab (session, split, Changes or file) onto another to move it there; a bar on the target's leading edge
/// shows where it lands. The order is kept by `AppModel.moveTab`.
private struct TabReordering: ViewModifier {
    @Environment(AppModel.self) private var model
    let tab: DetailTab
    let context: SessionContext
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .draggable(tab.dragPayload)
            .dropDestination(for: String.self) { items, _ in
                guard let dragged = items.first.flatMap(DetailTab.init(dragPayload:)) else { return false }
                withAnimation(.snappy(duration: 0.2)) { model.moveTab(dragged, onto: tab, in: context) }
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay(alignment: .leading) {
                if isTargeted {
                    Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 4)
                        .transition(.opacity)
                }
            }
    }
}

private struct SessionTab: View {
    @Environment(AppModel.self) private var model
    let session: AgentSessionRecord
    let paneCount: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        let activity = model.runtimes.activity(of: session)
        ToolbarTab(isSelected: isSelected, onClose: onClose, action: onSelect) {
            SessionStatusGlyph(activity: activity)
            AgentLogo(agent: model.runtimes.displayAgent(of: session), size: 14)
                .opacity(activity == .exited || activity == .failed ? 0.5 : 1)
            Text(verbatim: model.runtimes.displayTitle(of: session))
            PermissionsSkippedBadge(session: session)
            if paneCount > 1 {
                Label {
                    Text(verbatim: "\(paneCount)")
                } icon: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("\(paneCount) panes"))
            }
        }
        .help(Text(verbatim: model.sessionTooltip(of: session)))
        .contextMenu { SessionMenuItems(session: session) }
    }
}

/// One tab of the title-bar group: centered content, a close button on the leading edge on hover (as in Safari),
/// a raised background when selected.
private struct ToolbarTab<Label: View>: View {
    let isSelected: Bool
    let onClose: (() -> Void)?
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .font(.callout)
            .padding(.horizontal, 26)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background {
                if isSelected {
                    Capsule().fill(.background).shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                } else if isHovered {
                    Capsule().fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .overlay(alignment: .leading) {
            if let onClose, isHovered || isSelected {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 9)
                    .help(Text("Close tab and end the session (⌘W)"))
                    .accessibilityLabel(Text("Close tab"))
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The agent menu in the title bar: its label is the logo of the agent new sessions use (the one used last); the menu
/// lists every agent with its logo, each with its accounts when there are several, a shell and the full sheet.
/// Picking an agent starts a session with it and makes it the agent of `NewSessionButton` (⌘T).
struct NewSessionMenu: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext
    @State private var isConfiguring = false

    var body: some View {
        let agent = model.defaultAgent
        Menu {
            Section("New Session") {
                agentItem(.claude, title: "Claude Code")
                agentItem(.codex, title: "Codex")
                Button { start(.shell, account: nil) } label: {
                    Label { Text("Shell") } icon: { Image(systemName: "terminal") }
                }
                PermissionModeMenu { agent, mode in start(agent, account: nil, permissionMode: mode) }
            }
            Divider()
            Button("New Session with Prompt…") { isConfiguring = true }
        } label: {
            // A fixed-size image: toolbar menu labels ignore SwiftUI frames on resizable images.
            Label {
                Text("Agent: \(Self.name(of: agent))")
            } icon: {
                Image(nsImage: Self.buttonIcon(agent))
            }
            .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Text("Start a session with another agent or account. New sessions use \(Self.name(of: agent))."))
        .accessibilityLabel(Text("Choose agent, \(Self.name(of: agent)) selected"))
        .sheet(isPresented: $isConfiguring) { NewSessionSheet(context: context) }
    }

    /// One agent in the menu: a plain item, or a submenu of its accounts when the user manages more than one.
    @ViewBuilder
    private func agentItem(_ agent: AgentKind, title: LocalizedStringKey) -> some View {
        let provider = agent.accountProvider ?? .claude
        let accounts = model.accounts.filter { $0.provider == provider }
        if accounts.isEmpty {
            Button { start(agent, account: nil) } label: {
                Label { Text(title) } icon: { Image(nsImage: Self.menuIcon(agent)) }
            }
        } else {
            Menu {
                Button { start(agent, account: nil) } label: {
                    Text("Default (\(model.defaultAccount(for: provider)?.displayName ?? String(localized: "your own login")))")
                }
                Divider()
                ForEach(accounts) { account in
                    Button(account.displayName) { start(agent, account: account.id) }
                }
            } label: {
                Label { Text(title) } icon: { Image(nsImage: Self.menuIcon(agent)) }
            }
        }
    }

    private func start(_ agent: AgentKind, account: UUID?, permissionMode: AgentPermissionMode? = nil) {
        if agent != .shell, agent != model.defaultAgent { model.setSetting(.defaultAgent, agent.rawValue) }
        Task {
            await model.runtimes.start(in: context, agent: agent, accountID: account, prompt: nil,
                                       permissionMode: permissionMode)
        }
    }

    static func name(of agent: AgentKind) -> String {
        switch agent {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .shell: String(localized: "Shell")
        }
    }

    /// Images made once per agent: a new `NSImage` on every render reads as a changed image, so the toolbar would
    /// update the item (and its menu form) each time the toolbar re-renders.
    private static var buttonIcons: [AgentKind: NSImage] = [:]
    private static var menuIcons: [AgentKind: NSImage] = [:]

    /// The agent menu's image: the agent's logo (a terminal symbol for a shell), 30 × 18 pt.
    static func buttonIcon(_ agent: AgentKind) -> NSImage {
        if let image = buttonIcons[agent] { return image }
        let image = makeButtonIcon(agent)
        buttonIcons[agent] = image
        return image
    }

    private static func makeButtonIcon(_ agent: AgentKind) -> NSImage {
        let logo = agent == .shell
            ? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor])) ?? NSImage()
            : menuIcon(agent)
        // Room on both sides of the logo, so the toolbar draws the menu as a pill rather than a tight circle.
        let image = NSImage(size: NSSize(width: 30, height: 18), flipped: false) { _ in
            logo.draw(in: NSRect(x: 8, y: 1, width: 16, height: 16))
            return true
        }
        // The drawing handler runs again for each appearance, so the shell symbol's `labelColor` reads in light and
        // dark; the logos keep their own colors.
        image.isTemplate = false
        return image
    }

    /// Menus draw images at their own size: the logo scaled to 16 pt.
    static func menuIcon(_ agent: AgentKind) -> NSImage {
        if let image = menuIcons[agent] { return image }
        let source = NSImage(named: agent == .codex ? "CodexLogo" : "ClaudeLogo") ?? NSImage()
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        menuIcons[agent] = image
        return image
    }
}

/// Starts a session with the selected agent at once (⌘T); `NewSessionMenu` beside it picks another agent.
struct NewSessionButton: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext

    var body: some View {
        let agent = model.defaultAgent
        Button {
            Task { await model.runtimes.start(in: context, agent: agent, accountID: nil, prompt: nil) }
        } label: {
            Label("New \(NewSessionMenu.name(of: agent)) Session", systemImage: "plus")
        }
        .help(Text("New \(NewSessionMenu.name(of: agent)) session (⌘T)"))
    }
}

/// Agent, account and first prompt for a new session in an existing context.
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let context: SessionContext
    @State private var agent: AgentKind = .claude
    @State private var accountID: UUID?
    @State private var prompt = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isFolder, !model.sessions(in: context).isEmpty {
                    Label("Another session already works in this folder. Agents here edit the same files.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(SuijinColor.warningText)
                }
                AgentLaunchFields(agent: $agent, accountID: $accountID, prompt: $prompt, allowsShell: true)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    let agent = agent, accountID = accountID, prompt = prompt
                    dismiss()
                    Task { await model.runtimes.start(in: context, agent: agent, accountID: accountID, prompt: agent == .shell ? nil : prompt) }
                }
                .glassProminentButtonStyle()
                .keyboardShortcut(.defaultAction)
            }
            .padding(SuijinSpacing.l)
        }
        .frame(width: 460)
    }

    private var isFolder: Bool {
        guard let id = model.workspaceID(of: context) else { return false }
        return model.workspace(id)?.kind == .folder
    }
}

/// The empty state of a context: where agents will run, and one large card per agent (its logo, name and what it
/// starts with) as real Liquid Glass buttons on macOS 26 (bordered before). The default agent's card says so.
private struct NoSessionView: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext

    static let cornerRadius: CGFloat = 28

    var body: some View {
        VStack(spacing: SuijinSpacing.xl) {
            VStack(spacing: SuijinSpacing.s) {
                Text("Start a Session").font(.title2.weight(.semibold))
                if let directory = model.directory(of: context) {
                    Label {
                        Text(verbatim: (directory.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                }
            }
            GlassGroup(spacing: SuijinSpacing.m) {
                HStack(spacing: SuijinSpacing.m) {
                    card(.claude, title: "Claude Code", detail: detail(for: .claude))
                    card(.codex, title: "Codex", detail: detail(for: .codex))
                    card(.shell, title: "Shell", detail: Text(verbatim: "⌥⌘T"))
                }
            }
            .frame(maxWidth: 560)
        }
        .padding(SuijinSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The account a new session would use, and the shortcut for the default agent.
    private func detail(for agent: AgentKind) -> Text {
        let account = agent.accountProvider.flatMap { model.defaultAccount(for: $0) }?.displayName
        let shortcut = agent == model.defaultAgent ? String(localized: "Default · ⌘T") : nil
        let parts = [account, shortcut].compactMap(\.self)
        return parts.isEmpty ? Text("Your own login") : Text(verbatim: parts.joined(separator: " · "))
    }

    @ViewBuilder
    private func card(_ agent: AgentKind, title: LocalizedStringKey, detail: Text) -> some View {
        let button = Button {
            Task { await model.runtimes.start(in: context, agent: agent, accountID: nil, prompt: nil) }
        } label: {
            VStack(spacing: SuijinSpacing.s) {
                Group {
                    if agent == .shell {
                        Image(systemName: "terminal").font(.system(size: 30, weight: .regular))
                    } else {
                        AgentLogo(agent: agent, size: 36)
                    }
                }
                .frame(height: 40)
                Text(title).font(.headline).foregroundStyle(.primary)
                detail.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SuijinSpacing.xl)
            .padding(.horizontal, SuijinSpacing.m)
            // Real interactive Liquid Glass in a generously rounded card (system button styles keep a small radius
            // at this size); a plain control background before macOS 26.
            .floatingGlass(in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Start \(Text(title))"))
        button
    }
}

/// Shown while a session's screen is not ready: one that kept running in the background comes back after launch, or a
/// resumed agent re-prints its conversation.
private struct SessionProgressView: View {
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: SuijinSpacing.m) {
            ProgressView().controlSize(.regular)
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}

/// A session whose process ended: a Liquid Glass card in the style of the start screen with the agent, how the session
/// ended, how long it ran and where, and large glass buttons to start it again or close the tab.
private struct EndedSessionView: View {
    @Environment(AppModel.self) private var model
    let record: AgentSessionRecord
    let closeTitle: LocalizedStringKey

    private static let cornerRadius: CGFloat = 28
    private var failed: Bool { record.state == .failed || (record.exitCode ?? 0) != 0 }
    private var canResume: Bool { model.canResume(record) }

    var body: some View {
        VStack(spacing: SuijinSpacing.l) {
            VStack(spacing: SuijinSpacing.m) {
                logo
                VStack(spacing: SuijinSpacing.xs) {
                    Text(verbatim: model.runtimes.displayTitle(of: record))
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    status
                }
                details
                if failed, let output = model.runtimes.endedOutput[record.id] { lastOutput(output) }
            }
            .padding(SuijinSpacing.xl)
            .frame(maxWidth: .infinity)
            .floatingGlass(in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            GlassGroup(spacing: SuijinSpacing.m) {
                // Side by side when they fit; a narrow pane stacks them so no title is cut.
                ViewThatFits(in: .horizontal) {
                    EqualWidthRow(spacing: SuijinSpacing.m) { actions }
                    VStack(spacing: SuijinSpacing.s) { actions }
                }
            }
            if record.agent != .shell, !model.continueTargets(for: record).isEmpty {
                ContinueWithAccountMenu(session: record)
                    .menuStyle(.button)
                    .glassButtonStyle()
                    .fixedSize()
                    .help(Text("Continue this conversation on another account, in this place"))
            }
        }
        .frame(maxWidth: canResume ? 520 : 440)
        .padding(SuijinSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var actions: some View {
        // Resuming continues the conversation, so it is the main action whenever it is possible.
        if canResume {
            action("Resume Session", systemImage: "play.fill", tint: .accentColor) {
                Task { await model.resume(record) }
            }
            .keyboardShortcut(.defaultAction)
            .help(Text("Continue this conversation in this place"))
            action("Start Again", systemImage: "arrow.clockwise", tint: nil) {
                Task { await model.startAgain(record) }
            }
            .help(Text("Start a new conversation"))
        } else {
            action("Start Again", systemImage: "arrow.clockwise", tint: .accentColor) {
                Task { await model.startAgain(record) }
            }
            .keyboardShortcut(.defaultAction)
        }
        action(closeTitle, systemImage: "xmark", tint: nil) {
            Task { await model.closeSession(record.id) }
        }
    }

    /// The agent's logo (a terminal symbol for a shell) with a small badge saying how it ended.
    private var logo: some View {
        Group {
            if record.agent == .shell {
                Image(systemName: "terminal").font(.system(size: 38, weight: .regular)).foregroundStyle(.secondary)
            } else {
                AgentLogo(agent: record.agent, size: 46)
            }
        }
        .frame(width: 56, height: 56)
        .opacity(0.85)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: failed ? "xmark.circle.fill" : "stop.circle.fill")
                .font(.system(size: 18))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, failed ? Color.red : Color.secondary)
                .offset(x: 4, y: 4)
        }
        .accessibilityHidden(true)
    }

    /// "Session ended" or "Exited with code 1", tinted by outcome.
    private var status: some View {
        Group {
            if let code = record.exitCode, code != 0 {
                Text("Exited with code \(code)")
            } else if record.state == .failed {
                Text("Session failed")
            } else {
                Text("Session ended")
            }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(failed ? Color.red : Color.secondary)
    }

    /// How long it ran, when it ended and its folder.
    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: SuijinSpacing.m, verticalSpacing: SuijinSpacing.xs) {
            if let ended = record.endedAt {
                GridRow {
                    Text("Ran for").foregroundStyle(.secondary)
                    Text(verbatim: Duration.seconds(max(0, ended.timeIntervalSince(record.createdAt)))
                        .formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))
                }
                GridRow {
                    Text("Ended").foregroundStyle(.secondary)
                    Text(ended, format: .relative(presentation: .named))
                }
            }
            GridRow {
                Text("Folder").foregroundStyle(.secondary)
                Text(verbatim: (record.cwd as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: record.cwd))
            }
        }
        .font(.callout)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// What a failed session printed last (its error, usually): the terminal is gone with the process.
    private func lastOutput(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: SuijinSpacing.xs) {
            Text("Last output").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            // At most `SessionRuntimeRegistry.endedOutputLines` lines; long ones wrap. Never `.fixedSize` vertically:
            // asked for its smallest size, such a text wraps every character onto its own line (over 1,000 points for
            // one line of output), the window's whole content grows taller than the window and slides under the title
            // bar, sidebar and inspector included.
            Text(verbatim: output)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// A large rounded Liquid Glass button (system button styles keep a small radius at this size).
    private func action(_ title: LocalizedStringKey, systemImage: String, tint: Color?, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(tint == nil ? Color.primary : Color.white)
                .padding(.horizontal, SuijinSpacing.m)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SuijinSpacing.m)
                .floatingGlass(in: Capsule(), tint: tint, interactive: true)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A row of equally wide views, each as wide as the widest one needs. `HStack` shares its width out evenly instead, so
/// with `ViewThatFits` a row whose views fit in total could still cut the longest title. Custom because no system
/// stack sizes its children this way (Apple's sample layout for this case).
private struct EqualWidthRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let widest = maxSize(subviews)
        let width = widest.width * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1)
        // Fills an offered width it fits in, so wide windows keep the buttons stretched as before.
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? width
        return CGSize(width: max(width, offered), height: widest.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count)
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func maxSize(_ subviews: Subviews) -> CGSize {
        subviews.map { $0.sizeThatFits(.unspecified) }.reduce(.zero) {
            CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height))
        }
    }
}

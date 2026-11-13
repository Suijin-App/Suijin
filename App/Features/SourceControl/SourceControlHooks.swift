import AppKit
import SwiftUI

/// Source control in the inspector of a git context (staging, commit, push, pull request status).
struct SourceControlSection: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext

    var body: some View {
        let state = SourceControlStore.shared(for: model).state(for: context)
        SourceControlPanel(state: state)
            // The periodic refresh runs in `SourceControlToolbarItems`, which is shown whenever this section is.
            .task(id: context) { await state.refreshStatus() }
            .sheet(item: Binding(get: { state.outputReport(on: .inspector) }, set: { if $0 == nil { state.outputReport = nil } })) {
                GitOutputSheet(report: $0)
            }
            .sheet(isPresented: Binding(get: { state.createPullRequestSurface == .inspector },
                                        set: { if !$0 { state.createPullRequestSurface = nil } })) {
                CreatePullRequestSheet(state: state)
            }
    }
}

/// Source control buttons in the window toolbar for the selected git context (commit, push, create pull request).
/// They also drive the gentle refresh: the file status every few seconds and the pull request when the context opens
/// and then every two minutes, only for this visible context.
struct SourceControlToolbarItems: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext
    @State private var isCommitPopoverShown = false

    var body: some View {
        let state = SourceControlStore.shared(for: model).state(for: context)
        HStack(spacing: 0) {
            Button { isCommitPopoverShown.toggle() } label: {
                Label("Commit", systemImage: "checkmark.circle")
            }
            .help(Text("Stage changes and commit"))
            .popover(isPresented: $isCommitPopoverShown, arrowEdge: .bottom) {
                CommitPopover(state: state)
            }
            ToolbarPushButton(state: state)
            PullRequestToolbarButton(state: state)
        }
        .task(id: context) {
            await state.refreshStatus()
            #if DEBUG
            await openLaunchSurface(state)
            #endif
            // Opening a context reads its pull request, unless that happened moments ago (switching back and forth).
            if state.pullRequestCheckedAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
                await state.refreshPullRequest()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, NSApp.isActive else { continue }
                await state.refreshStatus()
                if state.isPullRequestStale { await state.refreshPullRequest() }
            }
        }
        .sheet(item: Binding(get: { state.outputReport(on: .toolbar) }, set: { if $0 == nil { state.outputReport = nil } })) {
            GitOutputSheet(report: $0)
        }
        .sheet(isPresented: Binding(get: { state.createPullRequestSurface == .toolbar },
                                    set: { if !$0 { state.createPullRequestSurface = nil } })) {
            CreatePullRequestSheet(state: state)
        }
    }
}

#if DEBUG
extension SourceControlToolbarItems {
    /// Screenshot runs open a surface directly, once per launch: `-SuijinSourceControl commit|pullRequest|commitError`.
    /// `commitError` commits the staged changes with a sample message, so a failing pre-commit hook shows its report.
    /// `-SuijinShowSidebar YES` toggles the sidebar open; `-SuijinShowInspector YES` shows the inspector by sending its ⌥⌘I shortcut to the main window.
    private func openLaunchSurface(_ state: SourceControlState) async {
        guard !Self.openedLaunchSurface else { return }
        Self.openedLaunchSurface = true
        try? await Task.sleep(for: .seconds(1))
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "SuijinShowInspector") || defaults.bool(forKey: "SuijinShowSidebar")
                || defaults.string(forKey: "SuijinSourceControl") != nil else { return }
        // A screenshot run is started from a script; bring the window forward so it renders as the active window.
        NSApp.activate()
        if defaults.bool(forKey: "SuijinShowSidebar") {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        }
        if defaults.bool(forKey: "SuijinShowInspector"), let window = NSApp.mainWindow ?? NSApp.windows.first,
           let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "i",
                                        charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34) {
            _ = window.performKeyEquivalent(with: event)
        }
        guard let surface = UserDefaults.standard.string(forKey: "SuijinSourceControl") else { return }
        switch surface {
        case "commit": isCommitPopoverShown = true
        case "pullRequest": state.createPullRequestSurface = .toolbar
        case "commitError":
            state.draftMessage = "fix: retry the login when the token endpoint times out"
            await state.commit(from: .toolbar)
        default: break
        }
    }

    @MainActor private static var openedLaunchSurface = false
}
#endif

/// The pull request state of a worktree's branch, shown on its sidebar row.
struct PullRequestBadge: View {
    @Environment(AppModel.self) private var model
    let worktreeID: UUID

    var body: some View {
        let state = SourceControlStore.shared(for: model).state(for: .worktree(worktreeID))
        PullRequestBadgeContent(state: state)
            // Each worktree reads its pull request once when its row first appears; after that only the visible
            // context refreshes (see `SourceControlToolbarItems`).
            .task(id: worktreeID) {
                if state.pullRequestCheckedAt == nil { await state.refreshPullRequest() }
            }
    }
}

/// The toolbar's pull request button: opens the existing pull request, or the Create Pull Request sheet.
private struct PullRequestToolbarButton: View {
    let state: SourceControlState

    var body: some View {
        if let pr = state.currentPullRequest, pr.state == .open {
            Button { NSWorkspace.shared.open(pr.url) } label: {
                Label("Open Pull Request", systemImage: "arrow.triangle.pull")
            }
            .help(Text("Open pull request #\(pr.number) in the browser"))
        } else {
            Button { state.createPullRequestSurface = .toolbar } label: {
                Label("Create Pull Request", systemImage: "arrow.triangle.pull")
            }
            .help(Text("Create a pull request on GitHub"))
            .disabled(!(state.status?.hasCommits ?? false) || state.status?.branch == nil)
        }
    }
}

/// The toolbar's commit popover: the same staging lists and message editor as the inspector.
private struct CommitPopover: View {
    let state: SourceControlState

    var body: some View {
        Form {
            if let status = state.status {
                Section {
                    HStack {
                        Label { Text(verbatim: status.branch ?? String(localized: "Detached HEAD")) } icon: {
                            Image(systemName: "arrow.triangle.branch")
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                        Spacer()
                        PushButton(state: state, surface: .toolbar)
                    }
                }
                Section("Commit") {
                    CommitComposer(state: state, surface: .toolbar)
                }
                SourceControlFileSections(state: state, status: status, surface: .toolbar)
            } else if let error = state.statusError {
                Text(verbatim: error).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        // A popover sizes a Form to its minimum height; a fixed size keeps the lists readable (the Form scrolls).
        .frame(width: 380, height: 540)
    }
}

import Foundation
import SwiftUI

/// The steps of the welcome tour, in order: a welcome, one step per feature area, and a last step that gets the user
/// started.
enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome, workspaces, sessions, changes, accounts, getStarted

    var id: Self { self }

    /// The position in the tour, from 0.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var title: LocalizedStringKey {
        switch self {
        case .welcome: "Welcome to Suijin"
        case .workspaces: "Workspaces & Worktrees"
        case .sessions: "Sessions, Tabs & Split Panes"
        case .changes: "Changes, Diff & Pull Requests"
        case .accounts: "Accounts, Usage & Stats"
        case .getStarted: "You’re All Set"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .welcome: "Claude Code and Codex agents side by side, each in a git worktree of its own. Everything runs locally on your Mac."
        case .workspaces: "Bring in a repository or a folder, then give every agent a worktree of its own."
        case .sessions: "Run agents and shells in tabs, or several at once in split panes."
        case .changes: "Review what the agents changed and ship it without leaving Suijin."
        case .accounts: "Use several subscriptions and keep an eye on what they cost."
        case .getStarted: "Add your first workspace and start an agent in it."
        }
    }

    /// The SF Symbol that stands for the step (page indicator help, small headers).
    var systemImage: String {
        switch self {
        case .welcome: "sparkles"
        case .workspaces: "square.stack.3d.up"
        case .sessions: "rectangle.split.2x1"
        case .changes: "plusminus"
        case .accounts: "person.2"
        case .getStarted: "checkmark.seal"
        }
    }

    /// The bundled capture of the feature (asset catalog, light and dark), nil for the welcome and last steps.
    var screenshot: String? {
        switch self {
        case .welcome, .getStarted: nil
        case .workspaces: "OnboardingWorkspaces"
        case .sessions: "OnboardingSessions"
        case .changes: "OnboardingChanges"
        case .accounts: "OnboardingAccounts"
        }
    }

    /// What the screenshot shows, for VoiceOver.
    var screenshotDescription: LocalizedStringKey {
        switch self {
        case .welcome, .getStarted: ""
        case .workspaces: "The sidebar with repositories, their worktrees and the sessions running in them"
        case .sessions: "A split tab with Claude, Codex and a shell, while a pane is dragged to a new place"
        case .changes: "The Changes tab with the changed files, the commits and a diff"
        case .accounts: "Settings, Stats & Usage, with tokens, cost and activity per day"
        }
    }

    /// The short "how to use" points of a feature step; empty for the welcome and last steps.
    var points: [OnboardingPoint] {
        switch self {
        case .welcome, .getStarted:
            []
        case .workspaces:
            [OnboardingPoint(symbol: "plus.rectangle.on.folder", text: "Add a git repository or a plain folder.", shortcuts: ["⇧⌘O"]),
             OnboardingPoint(symbol: "arrow.triangle.branch", text: "Create a worktree on a new branch.", shortcuts: ["⌘N"]),
             OnboardingPoint(symbol: "person.2.wave.2", text: "Each agent works in its own worktree, so their changes never collide."),
             OnboardingPoint(symbol: "sidebar.left", text: "The sidebar shows every workspace, worktree and session status.")]
        case .sessions:
            [OnboardingPoint(symbol: "plus.square.on.square", text: "Start an agent from the picker, or a shell.", shortcuts: ["⌘T", "⌥⌘T"]),
             OnboardingPoint(symbol: "rectangle.split.2x1", text: "Split the tab to the right or down.", shortcuts: ["⌘D", "⇧⌘D"]),
             OnboardingPoint(symbol: "hand.draw", text: "Drag tabs to reorder them. Drag a pane’s header onto an edge to place it there, or onto the center to swap."),
             OnboardingPoint(symbol: "arrow.up.left.and.arrow.down.right", text: "Move focus between panes, or zoom the focused one.", shortcuts: ["⌥⌘←→", "⇧⌘↩"])]
        case .changes:
            [OnboardingPoint(symbol: "plusminus", text: "Review every change in the native diff viewer on the Changes tab."),
             OnboardingPoint(symbol: "checkmark.circle", text: "Commit, push and create a pull request from the same tab.", shortcuts: ["⌘↩"]),
             OnboardingPoint(symbol: "sidebar.right", text: "Browse the worktree’s files in the inspector.", shortcuts: ["⌥⌘I"]),
             OnboardingPoint(symbol: "cursorarrow.click", text: "⌘-click an underlined path in a terminal to open it, or right-click it for more.")]
        case .accounts:
            [OnboardingPoint(symbol: "person.crop.circle.badge.plus", text: "Add managed Claude and Codex accounts. Your own logins stay untouched."),
             OnboardingPoint(symbol: "gauge.with.dots.needle.50percent", text: "See each plan’s usage in the status bar."),
             OnboardingPoint(symbol: "chart.bar", text: "Tokens, cost and activity live in Settings, Stats & Usage.", shortcuts: ["⌘,"]),
             OnboardingPoint(symbol: "memorychip", text: "Click the session count in the status bar for the Resource Manager.")]
        }
    }
}

/// One "how to use" line of a step: a symbol, a sentence, and the keyboard shortcuts it mentions.
struct OnboardingPoint: Identifiable {
    let symbol: String
    let text: LocalizedStringKey
    /// Shortcuts as printed in menus ("⇧⌘O"); each is shown as one key cap.
    var shortcuts: [String] = []

    var id: String { symbol }
}

/// Where the welcome tour is: the step shown and the direction the last move went, which the step transition
/// follows. Pure value logic, so navigation is tested without a window.
struct OnboardingTour: Equatable {
    enum Direction: Equatable { case forward, backward }

    private(set) var step: OnboardingStep
    private(set) var direction: Direction = .forward

    init(step: OnboardingStep = .welcome) {
        self.step = step
    }

    var isFirst: Bool { step.index == 0 }
    var isLast: Bool { step.index == OnboardingStep.allCases.count - 1 }

    /// Moves to the next step; false (and nothing changes) on the last one.
    @discardableResult
    mutating func advance() -> Bool { go(to: step.index + 1) }

    /// Moves to the previous step; false (and nothing changes) on the first one.
    @discardableResult
    mutating func back() -> Bool { go(to: step.index - 1) }

    /// Shows the step at `index`; false when it is out of range or already shown.
    @discardableResult
    mutating func go(to index: Int) -> Bool {
        let steps = OnboardingStep.allCases
        guard steps.indices.contains(index), index != step.index else { return false }
        direction = index > step.index ? .forward : .backward
        step = steps[index]
        return true
    }
}

/// A key the tour reacts to while it is shown.
enum OnboardingKey: Equatable {
    case left, right, returnKey, escape

    /// The key of a key-down event (`NSEvent.keyCode`) without command, option or control; nil for any other key.
    init?(keyCode: UInt16, hasCommandModifiers: Bool) {
        guard !hasCommandModifiers else { return nil }
        switch keyCode {
        case 123: self = .left
        case 124: self = .right
        case 36, 76: self = .returnKey
        case 53: self = .escape
        default: return nil
        }
    }
}

/// What a key does in the tour.
enum OnboardingCommand: Equatable {
    case back, advance, close, addWorkspace
    /// Show this step (a click on the page indicator).
    case show(OnboardingStep)
    /// The key does nothing at this step (← on the first one, → on the last one).
    case none
}

extension OnboardingTour {
    /// ← goes back, → and Return go on, Esc closes. On the last step Return runs its primary action (Add Workspace)
    /// and → does nothing.
    func command(for key: OnboardingKey) -> OnboardingCommand {
        switch key {
        case .left: isFirst ? .none : .back
        case .right: isLast ? .none : .advance
        case .returnKey: isLast ? .addWorkspace : .advance
        case .escape: .close
        }
    }
}

/// Whether the tour opens by itself at launch.
enum OnboardingLaunchPolicy {
    /// The launch argument that opens the tour (at a step: `-SuijinOnboarding sessions`) even when it was completed;
    /// screenshot runs use it.
    static let forceArgument = "SuijinOnboarding"

    /// The tour shows once, on the first launch. It stays closed under tests and in scripted runs: any `-Suijin…`
    /// launch argument (screenshots, demo panes, a forced appearance) means the window is being driven, unless that
    /// argument is `-SuijinOnboarding` itself.
    static func shouldAutoShow(completed: Bool, environment: [String: String], launchArguments: Set<String>) -> Bool {
        if launchArguments.contains(forceArgument) { return true }
        guard !completed else { return false }
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil { return false }
        return !launchArguments.contains { $0.hasPrefix("Suijin") }
    }

    /// The step a forced launch opens at: the argument's value when it names a step, else the first step.
    static func forcedStep(_ value: String?) -> OnboardingStep {
        value.flatMap(OnboardingStep.init(rawValue:)) ?? .welcome
    }
}

extension AppModel {
    var isOnboardingCompleted: Bool { setting(.onboardingCompleted) == "true" }

    /// Opens the tour at launch when `OnboardingLaunchPolicy` says so. Call after `loadSettings()`.
    func showOnboardingIfNeeded(environment: [String: String] = ProcessInfo.processInfo.environment,
                                launchArguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)) {
        guard OnboardingLaunchPolicy.shouldAutoShow(completed: isOnboardingCompleted, environment: environment,
                                                    launchArguments: Set(launchArguments.keys)) else { return }
        let forced = launchArguments[OnboardingLaunchPolicy.forceArgument] as? String
        showOnboarding(at: OnboardingLaunchPolicy.forcedStep(forced))
    }

    /// Opens the tour (Help › Welcome to Suijin), closing Settings first.
    func showOnboarding(at step: OnboardingStep = .welcome) {
        settingsPage = nil
        onboarding = OnboardingTour(step: step)
    }

    /// Closes the tour however it ends (Done, Skip, Esc, a last-step action); it no longer opens at launch.
    func finishOnboarding() {
        onboarding = nil
        if !isOnboardingCompleted { setSetting(.onboardingCompleted, "true") }
    }
}

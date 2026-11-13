import Foundation
import SuijinCore
import SuijinTerminal

/// The agents running in a shell session, innermost last, as the shell functions' markers report them
/// (`ShellAgentMarker`). A start pushes its agent; an end removes the latest run of that agent and anything started
/// inside it (which cannot outlive it). Names Suijin does not know, and ends without a start (a replay that lost the
/// start, a second report of the same end), change nothing.
struct ShellAgentStack: Equatable {
    private(set) var agents: [AgentKind] = []

    /// Deeper than any real nesting; a program printing starts forever cannot grow the stack.
    static let maximumDepth = 8

    /// The agent the session shows, nil while the shell itself is in front.
    var current: AgentKind? { agents.last }

    /// Applies `marker`; returns whether it started or ended a run.
    @discardableResult
    mutating func apply(_ marker: ShellAgentMarker) -> Bool {
        switch marker {
        case .started(let name):
            guard let kind = Self.kind(named: name) else { return false }
            if agents.count == Self.maximumDepth { agents.removeFirst() }
            agents.append(kind)
            return true
        case .ended(let name, _):
            guard let kind = Self.kind(named: name), let index = agents.lastIndex(of: kind) else { return false }
            agents.removeSubrange(index...)
            return true
        }
    }

    static func kind(named name: String) -> AgentKind? {
        switch name {
        case "claude": .claude
        case "codex": .codex
        default: nil
        }
    }
}

extension SessionRuntime {
    /// What runs in front: the agent started in this shell, else the session's own program.
    var activeAgent: AgentKind { shellAgentStack.current ?? agent }
}

extension SessionRuntimeRegistry {
    /// The program a tab, pane or row shows for `session`: Claude or Codex while one runs in a shell session, else the
    /// session's own agent. The record keeps its kind, so Start Again still opens a shell.
    func displayAgent(of session: AgentSessionRecord) -> AgentKind {
        guard session.agent == .shell else { return session.agent }
        return shellAgents[session.id] ?? .shell
    }

    /// Follows the agents a shell runtime's shell functions report. Other sessions print no markers that count.
    func observeShellAgents(_ runtime: SessionRuntime) {
        guard runtime.agent == .shell else { return }
        runtime.terminal.view.onShellAgentMarker { [weak self, weak runtime] marker in
            guard let self, let runtime else { return }
            shellAgentMarker(marker, in: runtime)
        }
    }

    /// An agent started or ended in the shell: the session takes on that agent (title, status, notifications, stats,
    /// paste guard) or goes back to being a shell. A scrollback replay (the app attaching again) restores what runs
    /// but counts nothing a second time.
    private func shellAgentMarker(_ marker: ShellAgentMarker, in runtime: SessionRuntime) {
        let before = runtime.activeAgent
        var stack = runtime.shellAgentStack
        guard stack.apply(marker) else { return }
        let replaying = runtime.terminal.view.isReplayingScrollback
        if before != .shell {
            // The agent in front is done or covered: keep the id it can be resumed with, close its working time.
            if !replaying, let conversation = Self.conversationID(of: runtime), conversation != runtime.agentSessionID {
                runtime.agentSessionID = conversation
                storeConversation(conversation, for: runtime.id)
            }
            trackWork(runtime, .idle)
        }
        runtime.shellAgentStack = stack
        shellAgents[runtime.id] = stack.current
        if case .started(let name) = marker, let kind = ShellAgentStack.kind(named: name) {
            // A new run reports its own conversation; the previous one's id must not be taken for it.
            runtime.agentSessionID = nil
            if !replaying { Task { await countStart(of: kind) } }
        }
        let view = runtime.terminal.view
        // An agent's multi-line paste is a prompt; a shell's runs as commands and is confirmed first.
        view.pasteGuardPolicy = stack.current == nil ? .always : .unlessBracketedPaste
        // The previous program's title (Claude names its task there) does not describe what runs now.
        view.onTitleChange?("")
        runtime.tracker.restart()
    }
}

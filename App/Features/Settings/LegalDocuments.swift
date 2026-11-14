import Foundation

/// The Terms of Service and the Privacy & Security policy shown in Settings → About.
///
/// The text lives here, one section per heading, so it is easy to edit; every string still goes through the String
/// Catalog. Paragraphs and bullets accept inline Markdown (`code`, **bold**). Keep each claim true to what the app
/// actually does, and move `effective` forward whenever the substance changes.
struct LegalDocument: Identifiable {
    enum Kind: String, Identifiable, CaseIterable {
        case terms, privacy
        var id: Self { self }
    }

    enum Block {
        case paragraph(AttributedString)
        case bullets([AttributedString])
    }

    struct Section {
        /// Nil for an untitled introduction.
        var heading: String?
        var blocks: [Block]
    }

    let kind: Kind
    let title: String
    let sections: [Section]

    var id: Kind { kind }

    /// The day both documents took effect.
    static let effective: Date = {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = 2026
        components.month = 11
        components.day = 14
        // A fixed, valid Gregorian day always resolves to a date.
        return components.date!
    }()

    static func document(_ kind: Kind) -> LegalDocument {
        switch kind {
        case .terms: terms
        case .privacy: privacy
        }
    }

    private static func text(_ value: AttributedString) -> Block { .paragraph(value) }

    // MARK: Terms of Service

    static var terms: LegalDocument {
        LegalDocument(kind: .terms, title: String(localized: "Terms of Service"), sections: [
            Section(heading: nil, blocks: [
                text(AttributedString(localized: "These terms apply to your use of Suijin, a Mac app made by Tekmium Solutions. By installing or using Suijin, you agree to them. If you do not agree, do not use Suijin.")),
            ]),
            Section(heading: String(localized: "Using Suijin"), blocks: [
                text(AttributedString(localized: "Tekmium Solutions grants you a personal, non-exclusive, non-transferable license to install and use Suijin on Macs you own or control.")),
                .bullets([
                    AttributedString(localized: "Do not sell, rent, sublicense or redistribute Suijin, or remove its copyright notices, without written permission from Tekmium Solutions."),
                    AttributedString(localized: "Suijin, its name and its icon belong to Tekmium Solutions."),
                    AttributedString(localized: "The open-source components inside Suijin stay under their own licenses, listed under Acknowledgements in Settings → About."),
                ]),
            ]),
            Section(heading: String(localized: "Agents and other services"), blocks: [
                text(AttributedString(localized: "Suijin starts programs you install yourself: Claude Code, Codex, git, the GitHub CLI and your shell. Your use of them, and of the accounts behind them, is governed by their providers' own terms (for example Anthropic, OpenAI and GitHub). Suijin does not provide those accounts or plans.")),
                text(AttributedString(localized: "Usage limits come from the providers, and costs on the Stats & Usage page are estimates from your local logs. They are for information only and may differ from what a provider bills you.")),
            ]),
            Section(heading: String(localized: "You are responsible for your agents"), blocks: [
                text(AttributedString(localized: "Agents act on your files. Depending on the permissions you give them, they can edit and delete files, run commands, commit and push.")),
                .bullets([
                    AttributedString(localized: "You choose the folders, accounts and permissions each agent gets."),
                    AttributedString(localized: "Review an agent's changes before you rely on them, and keep backups of work that matters."),
                    AttributedString(localized: "Tekmium Solutions is not responsible for what an agent does in your repositories, on your Mac or in your accounts."),
                ]),
            ]),
            Section(heading: String(localized: "No warranty"), blocks: [
                text(AttributedString(localized: "Suijin is provided “as is” and “as available”, without warranties of any kind, express or implied, including merchantability, fitness for a particular purpose and non-infringement. We do not promise that Suijin is free of errors, runs without interruption or works with every future version of the agents it starts.")),
            ]),
            Section(heading: String(localized: "Limitation of liability"), blocks: [
                text(AttributedString(localized: "As far as the law allows, Tekmium Solutions is not liable for indirect, incidental, special or consequential damages, or for lost data, code, work or profits, that arise from your use of Suijin. Nothing in these terms limits rights you have under laws that cannot be waived.")),
            ]),
            Section(heading: String(localized: "Updates"), blocks: [
                text(AttributedString(localized: "Suijin can offer updates through its built-in updater. An update may add, change or remove features, and these terms apply to it too.")),
            ]),
            Section(heading: String(localized: "Changes to these terms"), blocks: [
                text(AttributedString(localized: "We may update these terms. The effective date at the top shows the current version. Using Suijin after a change means you accept the updated terms.")),
            ]),
            Section(heading: String(localized: "Contact"), blocks: [
                text(AttributedString(localized: "For questions about these terms, contact Tekmium Solutions through the details in Settings → About.")),
            ]),
        ])
    }

    // MARK: Privacy & Security

    static var privacy: LegalDocument {
        LegalDocument(kind: .privacy, title: String(localized: "Privacy & Security"), sections: [
            Section(heading: nil, blocks: [
                text(AttributedString(localized: "Suijin works on your Mac. There are no Suijin servers and no Suijin account, and Suijin collects no analytics, telemetry or crash reports. This policy lists what Suijin reads, what it stores and the few connections it makes.")),
            ]),
            Section(heading: String(localized: "What Suijin reads"), blocks: [
                .bullets([
                    AttributedString(localized: "The folders and repositories you add as workspaces, to show their files and changes, run git and start agents in them."),
                    AttributedString(localized: "Your Claude Code and Codex logs (`~/.claude/projects`, `~/.codex/sessions` and those of the accounts Suijin manages), read-only, for the Stats & Usage page. Suijin keeps only token counts, model names, project folder names and dates from them, never the text of prompts or replies."),
                    AttributedString(localized: "The sign-in of your own Claude Code login (from the macOS Keychain) and Codex login (`~/.codex/auth.json`), to show how much of your plan's limits you have used."),
                ]),
            ]),
            Section(heading: String(localized: "What Suijin stores"), blocks: [
                text(AttributedString(localized: "Everything Suijin keeps is on your Mac, in `~/Library/Application Support/Suijin`:")),
                .bullets([
                    AttributedString(localized: "A database (`suijin.sqlite`) with your workspaces (name, folder, icon, color), worktrees, managed accounts (label, email, organization), session records (title, folder, status, times), split-pane layouts, the diff notes you write, your settings and the counters behind the Stats page."),
                    AttributedString(localized: "A usage cache with the numbers described above."),
                    AttributedString(localized: "A home folder for each managed account. Managed Claude sign-ins are kept in the macOS Keychain; managed Codex sign-ins stay in that account's folder, where Codex itself stores them."),
                    AttributedString(localized: "Events from open Claude Code sessions, including the prompts you send, so Suijin knows when an agent waits for you. Each session's file is deleted when you close its tab."),
                    AttributedString(localized: "Worker tasks and the messages between agents that coordinate them, kept up to 14 days after they finish, and pictures you choose for workspaces."),
                ]),
                text(AttributedString(localized: "Terminal output stays in the memory of Suijin's background helper, so sessions survive quitting the app. Suijin does not write it to disk.")),
            ]),
            Section(heading: String(localized: "Connections Suijin makes"), blocks: [
                .bullets([
                    AttributedString(localized: "**Usage limits.** For each Claude or Codex login whose limits Suijin shows, it asks Anthropic (`api.anthropic.com`) or OpenAI (`chatgpt.com`) with that login's own token, now and then and when you click refresh. Only the token (and the Codex account ID) is sent; the reply holds percentages and reset times."),
                    AttributedString(localized: "**Updates.** Suijin asks `suijin.app` whether a newer version exists, about once a day and when you choose Check for Updates; that address forwards to the releases of Suijin on GitHub (`github.com`), where an update is downloaded from. The request carries the app's name and version, nothing about you or your work. Turn the automatic check off in Settings → General."),
                    AttributedString(localized: "**GitHub.** If the GitHub CLI (`gh`) is installed, Suijin uses it with your own GitHub sign-in to show a branch's pull request and checks, and to create pull requests you ask for. When you ask for a workspace's GitHub avatar, Suijin downloads the repository owner's public picture from github.com."),
                    AttributedString(localized: "**Git.** Suijin pushes a branch only when you ask, using your own remotes and git credentials."),
                    AttributedString(localized: "**Markdown files.** When a Markdown file you open shows images from the web, they load from their addresses, as in a browser."),
                ]),
            ]),
            Section(heading: String(localized: "Agents are third-party programs"), blocks: [
                text(AttributedString(localized: "Claude Code (by Anthropic) and Codex (by OpenAI) are separate programs you install. Suijin starts them on your Mac, in the folders you choose. What they send to their providers, such as your prompts, code and files, is governed by those providers' terms and privacy policies. None of it passes through Tekmium Solutions.")),
                text(AttributedString(localized: "When you ask Suijin to write a commit message or a pull request description, it runs your agent with the changes as the prompt, so those changes go to that agent's provider as well.")),
            ]),
            Section(heading: String(localized: "Security"), blocks: [
                .bullets([
                    AttributedString(localized: "Suijin reads credentials into memory only for the request that needs them, and never prints or logs them."),
                    AttributedString(localized: "The folders Suijin creates for managed accounts and session events are readable only by your macOS user (permissions 700), and the files it writes there are 600."),
                    AttributedString(localized: "Suijin never changes your own Claude Code or Codex sign-ins or settings. Its Claude hooks are passed to each session it starts, not installed in your settings. It adds to `~/.claude` or `~/.codex` only: its orchestration guide in `~/.claude/skills`, if you turn that on in Settings → Agents; and when you continue a conversation with your own login, that conversation's history files, in `~/.claude/projects/<folder>` or `~/.codex/sessions/<date>`. It never replaces a file that is already there."),
                    AttributedString(localized: "Only terminals Suijin opened can reach its agent coordination service; each gets a private random token."),
                ]),
            ]),
            Section(heading: String(localized: "Your choices"), blocks: [
                .bullets([
                    AttributedString(localized: "Remove a workspace, account or session in Suijin at any time. Removing a workspace does not delete its folder."),
                    AttributedString(localized: "To remove everything Suijin stored, quit Suijin and delete `~/Library/Application Support/Suijin`."),
                    AttributedString(localized: "Turn off automatic update checks in Settings → General."),
                ]),
            ]),
            Section(heading: String(localized: "Changes to this policy"), blocks: [
                text(AttributedString(localized: "When Suijin's handling of data changes, we update this policy and the effective date at the top.")),
            ]),
            Section(heading: String(localized: "Contact"), blocks: [
                text(AttributedString(localized: "For questions about privacy or security, contact Tekmium Solutions through the details in Settings → About.")),
            ]),
        ])
    }
}

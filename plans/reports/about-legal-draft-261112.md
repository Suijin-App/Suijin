# Mercury — Terms of Service and Privacy & Security (draft)

> **Draft, not legal advice.** Written from what the code does on 2026-11-12 for review by the owner and, ideally, a
> lawyer before the first public release. The in-app source of truth is
> `App/Features/Settings/LegalDocuments.swift`; keep this file and that one in step.

Open points for review:

- The license clause assumes Mercury is proprietary (no LICENSE file in the repository). Change it if Mercury is
  open source or sold under a separate license.
- The contact sections point to "the details in Settings → About"; those links (`AboutLinks.supportEmail`,
  `AboutLinks.issueTracker` in `App/Features/Settings/AboutSettings.swift`) are still empty, so no contact is shown yet.
- The update feed host (`mercury.tekmium.com`) is the placeholder from `App/Info.plist`; update the policy if it changes.

## Terms of Service

*Effective November 13, 2026*

These terms apply to your use of Mercury, a Mac app made by Tekmium Solutions. By installing or using Mercury, you agree to them. If you do not agree, do not use Mercury.

### Using Mercury

Tekmium Solutions grants you a personal, non-exclusive, non-transferable license to install and use Mercury on Macs you own or control.

- Do not sell, rent, sublicense or redistribute Mercury, or remove its copyright notices, without written permission from Tekmium Solutions.
- Mercury, its name and its icon belong to Tekmium Solutions.
- The open-source components inside Mercury stay under their own licenses, listed under Acknowledgements in Settings → About.

### Agents and other services

Mercury starts programs you install yourself: Claude Code, Codex, git, the GitHub CLI and your shell. Your use of them, and of the accounts behind them, is governed by their providers' own terms (for example Anthropic, OpenAI and GitHub). Mercury does not provide those accounts or plans.

Usage limits come from the providers, and costs on the Stats & Usage page are estimates from your local logs. They are for information only and may differ from what a provider bills you.

### You are responsible for your agents

Agents act on your files. Depending on the permissions you give them, they can edit and delete files, run commands, commit and push.

- You choose the folders, accounts and permissions each agent gets.
- Review an agent's changes before you rely on them, and keep backups of work that matters.
- Tekmium Solutions is not responsible for what an agent does in your repositories, on your Mac or in your accounts.

### No warranty

Mercury is provided “as is” and “as available”, without warranties of any kind, express or implied, including merchantability, fitness for a particular purpose and non-infringement. We do not promise that Mercury is free of errors, runs without interruption or works with every future version of the agents it starts.

### Limitation of liability

As far as the law allows, Tekmium Solutions is not liable for indirect, incidental, special or consequential damages, or for lost data, code, work or profits, that arise from your use of Mercury. Nothing in these terms limits rights you have under laws that cannot be waived.

### Updates

Mercury can offer updates through its built-in updater. An update may add, change or remove features, and these terms apply to it too.

### Changes to these terms

We may update these terms. The effective date at the top shows the current version. Using Mercury after a change means you accept the updated terms.

### Contact

For questions about these terms, contact Tekmium Solutions through the details in Settings → About.


## Privacy & Security

*Effective November 13, 2026*

Mercury works on your Mac. There are no Mercury servers and no Mercury account, and Mercury collects no analytics, telemetry or crash reports. This policy lists what Mercury reads, what it stores and the few connections it makes.

### What Mercury reads

- The folders and repositories you add as workspaces, to show their files and changes, run git and start agents in them.
- Your Claude Code and Codex logs (`~/.claude/projects`, `~/.codex/sessions` and those of the accounts Mercury manages), read-only, for the Stats & Usage page. Mercury keeps only token counts, model names, project folder names and dates from them, never the text of prompts or replies.
- The sign-in of your own Claude Code login (from the macOS Keychain) and Codex login (`~/.codex/auth.json`), to show how much of your plan's limits you have used.

### What Mercury stores

Everything Mercury keeps is on your Mac, in `~/Library/Application Support/Mercury`:

- A database (`mercury.sqlite`) with your workspaces (name, folder, icon, color), worktrees, managed accounts (label, email, organization), session records (title, folder, status, times), split-pane layouts, the diff notes you write, your settings and the counters behind the Stats page.
- A usage cache with the numbers described above.
- A home folder for each managed account. Managed Claude sign-ins are kept in the macOS Keychain; managed Codex sign-ins stay in that account's folder, where Codex itself stores them.
- Events from open Claude Code sessions, including the prompts you send, so Mercury knows when an agent waits for you. Each session's file is deleted when you close its tab.
- Worker tasks and the messages between agents that coordinate them, kept up to 14 days after they finish, and pictures you choose for workspaces.
Terminal output stays in the memory of Mercury's background helper, so sessions survive quitting the app. Mercury does not write it to disk.

### Connections Mercury makes

- **Usage limits.** For each Claude or Codex login whose limits Mercury shows, it asks Anthropic (`api.anthropic.com`) or OpenAI (`chatgpt.com`) with that login's own token, now and then and when you click refresh. Only the token (and the Codex account ID) is sent; the reply holds percentages and reset times.
- **Updates.** Once a day by default, Mercury asks Tekmium's update feed (`mercury.tekmium.com`) whether a new version exists. You can turn this off in Settings → General. Sparkle's optional system profile is not turned on.
- **GitHub.** If the GitHub CLI (`gh`) is installed, Mercury uses it with your own GitHub sign-in to show a branch's pull request and checks, and to create pull requests you ask for. When you ask for a workspace's GitHub avatar, Mercury downloads the repository owner's public picture from github.com.
- **Git.** Mercury pushes a branch only when you ask, using your own remotes and git credentials.
- **Markdown files.** When a Markdown file you open shows images from the web, they load from their addresses, as in a browser.

### Agents are third-party programs

Claude Code (by Anthropic) and Codex (by OpenAI) are separate programs you install. Mercury starts them on your Mac, in the folders you choose. What they send to their providers, such as your prompts, code and files, is governed by those providers' terms and privacy policies. None of it passes through Tekmium Solutions.

When you ask Mercury to write a commit message or a pull request description, it runs your agent with the changes as the prompt, so those changes go to that agent's provider as well.

### Security

- Mercury reads credentials into memory only for the request that needs them, and never prints or logs them.
- The folders Mercury creates for managed accounts and session events are readable only by your macOS user (permissions 700), and the files it writes there are 600.
- Mercury never changes your own Claude Code or Codex sign-ins or settings. Its Claude hooks are passed to each session it starts, not installed in your settings. It adds to `~/.claude` or `~/.codex` only: its orchestration guide in `~/.claude/skills`, if you turn that on in Settings → Agents; and when you continue a conversation with your own login, that conversation's history files, in `~/.claude/projects/<folder>` or `~/.codex/sessions/<date>`. It never replaces a file that is already there.
- Only terminals Mercury opened can reach its agent coordination service; each gets a private random token.

### Your choices

- Remove a workspace, account or session in Mercury at any time. Removing a workspace does not delete its folder.
- To remove everything Mercury stored, quit Mercury and delete `~/Library/Application Support/Mercury`.
- Turn off automatic update checks in Settings → General.

### Changes to this policy

When Mercury's handling of data changes, we update this policy and the effective date at the top.

### Contact

For questions about privacy or security, contact Tekmium Solutions through the details in Settings → About.


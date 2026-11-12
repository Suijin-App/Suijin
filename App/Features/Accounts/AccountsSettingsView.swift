import SevindaAccounts
import SevindaCore
import SevindaUI
import SwiftUI

/// Settings → Accounts: managed Claude and Codex accounts, the default for each provider, add, sign in again, remove.
struct AccountsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: PendingLogin?
    @State private var removing: ManagedAccountRecord?

    var body: some View {
        Form {
            ForEach(AccountProvider.allCases, id: \.self) { provider in
                Section {
                    DefaultAccountPicker(provider: provider)
                    let accounts = model.accounts.filter { $0.provider == provider }
                    if accounts.isEmpty {
                        Label("No managed accounts. New sessions use your own login.", systemImage: "person.crop.circle.badge.questionmark")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(accounts) { account in
                        AccountRow(account: account,
                                   onRelogin: { Task { await relogin(account) } },
                                   onRemove: { removing = account })
                    }
                    HStack {
                        Spacer()
                        Button { Task { await add(provider) } } label: {
                            Label(provider == .claude ? "Add Claude Account…" : "Add Codex Account…", systemImage: "plus")
                        }
                    }
                } header: {
                    HStack(spacing: MercurySpacing.s) {
                        AgentLogo(agent: provider == .claude ? .claude : .codex, size: 16)
                        Text(provider == .claude ? "Claude Code" : "Codex")
                    }
                } footer: {
                    Text(provider == .claude
                         ? "Each account signs in with its own Claude subscription. Your own ~/.claude login is never changed; skills, settings and MCP servers are shared."
                         : "Each account has its own CODEX_HOME. Your own ~/.codex login is never changed; config.toml is mirrored into every account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $pending) { login in
            LoginSheet(pending: login)
        }
        .confirmationDialog(
            Text("Remove \(removing?.displayName ?? "")?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { account in
            Button("Sign Out and Remove", role: .destructive) { Task { await model.accountsController.remove(account) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Sessions using this account are stopped, the account is signed out and its folder is deleted.")
        }
    }

    private func add(_ provider: AccountProvider) async {
        await model.perform(String(localized: "Could not start the sign-in")) {
            pending = try await model.accountsController.beginAdding(provider)
        }
    }

    private func relogin(_ account: ManagedAccountRecord) async {
        await model.perform(String(localized: "Could not start the sign-in")) {
            pending = try await model.accountsController.beginRelogin(account)
        }
    }
}

private struct DefaultAccountPicker: View {
    @Environment(AppModel.self) private var model
    let provider: AccountProvider

    var body: some View {
        Picker("Default account", selection: Binding(
            get: { model.defaultAccount(for: provider)?.id },
            set: { id in Task { await model.accountsController.setDefault(id, for: provider) } }
        )) {
            Text("My own login").tag(UUID?.none)
            ForEach(model.accounts.filter { $0.provider == provider }) { account in
                Text(verbatim: account.displayName).tag(Optional(account.id))
            }
        }
        .help(Text("Used by new sessions and by `\(provider.rawValue)` typed in Mercury terminals"))
    }
}

/// One managed account: identity, usage, and its actions.
struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: ManagedAccountRecord
    let onRelogin: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: MercurySpacing.m) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: account.displayName).lineLimit(1).truncationMode(.middle)
                if let organization = account.organization {
                    Text(verbatim: organization).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: MercurySpacing.s)
            if let usage = model.accountsController.usage[account.id] {
                UsageSummary(usage: usage).font(.caption)
            }
            Menu {
                Button("Sign In Again…", action: onRelogin)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: account.homePath)]) }
                Divider()
                Button("Remove…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Actions for \(account.displayName)"))
        }
    }
}

/// "52% · 5h" style summary of the five-hour and seven-day windows.
struct UsageSummary: View {
    let usage: UsageSnapshot

    var body: some View {
        HStack(spacing: MercurySpacing.s) {
            if let window = usage.fiveHour { UsageGauge(window: window, label: Text("5h")) }
            if let window = usage.sevenDay { UsageGauge(window: window, label: Text("7d")) }
        }
    }
}

struct UsageGauge: View {
    let window: UsageWindow
    let label: Text

    var body: some View {
        let percent = Int((window.usedFraction * 100).rounded())
        HStack(spacing: 4) {
            Gauge(value: min(max(window.usedFraction, 0), 1)) { label }
                .gaugeStyle(.accessoryLinearCapacity)
                .labelsHidden()
                .tint(window.usedFraction > 0.9 ? MercuryColor.error : window.usedFraction > 0.7 ? MercuryColor.warning : MercuryColor.ok)
                .frame(width: 44)
            Text("\(label) \(percent)%").monospacedDigit()
            if let reset = window.resetsAt, reset > .now {
                Text(reset, format: .relative(presentation: .numeric, unitsStyle: .narrow)).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label) window \(percent) percent used"))
    }
}

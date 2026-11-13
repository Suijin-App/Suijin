import SevindaAccounts
import SevindaCore
import SevindaUI
import SwiftUI

/// Settings → Accounts: managed Claude and Codex accounts, the default for each provider, add, sign in again, remove,
/// and when running sessions switch accounts on their own.
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
                    HStack(spacing: SevindaSpacing.s) {
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
                AutoSwitchSettingsSection(provider: provider)
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
        .help(Text("Used by new sessions and by `\(provider.rawValue)` typed in Sevinda terminals"))
    }
}

/// One managed account: identity, usage, and its actions.
struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: ManagedAccountRecord
    let onRelogin: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: SevindaSpacing.m) {
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
            Spacer(minLength: SevindaSpacing.s)
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
        HStack(spacing: SevindaSpacing.s) {
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
                .tint(window.usedFraction > 0.9 ? SevindaColor.error : window.usedFraction > 0.7 ? SevindaColor.warning : SevindaColor.ok)
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

/// Automatic switching for one agent: following a new default account, and moving at a usage limit to the first account
/// with room in an order the user sets. Both off by default.
struct AutoSwitchSettingsSection: View {
    @Environment(AppModel.self) private var model
    let provider: AccountProvider

    var body: some View {
        Section {
            Toggle("Move running sessions when the default account changes", isOn: Binding(
                get: { model.movesOnDefaultChange(provider) },
                set: { model.setMovesOnDefaultChange(provider, $0) }))
            Toggle("Switch automatically when an account hits its limit", isOn: Binding(
                get: { model.switchesAtLimit(provider) },
                set: { model.setSwitchesAtLimit(provider, $0) }))
            if model.switchesAtLimit(provider) {
                let order = model.fallbackOrder(for: provider)
                ForEach(Array(order.enumerated()), id: \.element) { index, entry in
                    FallbackAccountRow(provider: provider, entry: entry, position: index + 1,
                                       onMoveUp: index > 0 ? { move(order, from: index, to: index - 1) } : nil,
                                       onMoveDown: index < order.count - 1 ? { move(order, from: index, to: index + 1) } : nil)
                }
                .onMove { source, destination in
                    var reordered = order
                    reordered.move(fromOffsets: source, toOffset: destination)
                    model.setFallbackOrder(reordered, for: provider)
                }
            }
        } header: {
            Text(provider == .claude ? "Claude Code: Automatic Switching" : "Codex: Automatic Switching")
        } footer: {
            Text("Sessions move with their conversation, as Continue With Another Account does, once their current turn ends. At a limit, a session moves to the first account in this order whose usage Sevinda knows and that has room; if none has, it stays and offers the choice. Shells are never moved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func move(_ order: [FallbackAccount], from: Int, to: Int) {
        var reordered = order
        reordered.swapAt(from, to)
        model.setFallbackOrder(reordered, for: provider)
    }
}

/// One account in the fallback order: its place, name and whether it has room, with buttons to move it.
private struct FallbackAccountRow: View {
    @Environment(AppModel.self) private var model
    let provider: AccountProvider
    let entry: FallbackAccount
    let position: Int
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    var body: some View {
        let name = model.accountName(entry.accountID, provider: provider)
        HStack(spacing: SevindaSpacing.s) {
            Text(verbatim: "\(position).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Image(systemName: entry == .ownLogin ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: SevindaSpacing.s)
            status
            Button { onMoveUp?() } label: { Image(systemName: "chevron.up") }
                .disabled(onMoveUp == nil)
                .help(Text("Move Up"))
                .accessibilityLabel(Text("Move \(name) up"))
            Button { onMoveDown?() } label: { Image(systemName: "chevron.down") }
                .disabled(onMoveDown == nil)
                .help(Text("Move Down"))
                .accessibilityLabel(Text("Move \(name) down"))
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var status: some View {
        if model.knownUsage(of: entry.accountID, provider: provider) == nil {
            Text("Usage unknown").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if !model.hasRoom(entry.accountID, provider: provider) {
            Text("At its limit").font(.caption).foregroundStyle(SevindaColor.warning).lineLimit(1)
        }
    }
}

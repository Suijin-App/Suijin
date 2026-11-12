import SwiftUI

/// Mercury → "Check for Updates…", right under "About Mercury".
struct UpdateCommands: Commands {
    var updater: UpdaterController = .shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

/// Settings → General → Updates: the daily check toggle, a manual check and the last check time.
struct UpdateSettingsSection: View {
    var updater: UpdaterController = .shared

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.setAutomaticallyChecks($0) }
            ))
            .disabled(updater.state != .running)
            LabeledContent("Last checked") {
                HStack {
                    Group {
                        if let date = updater.lastCheckDate {
                            Text(date, format: .relative(presentation: .named))
                        } else {
                            Text("Never")
                        }
                    }
                    .foregroundStyle(.secondary)
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            footer
        }
    }

    @ViewBuilder private var footer: some View {
        switch updater.state {
        case .notConfigured:
            Text("This build has no update signing key, so it does not check for updates.")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text("Updates are unavailable: \(message)")
                .font(.caption).foregroundStyle(.secondary)
        case .idle, .running:
            Text("Updates are verified with Mercury's signing key before they install. Running sessions keep going while Mercury restarts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

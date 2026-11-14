import SuijinUI
import SwiftUI

/// Settings › General › Permissions: what macOS allows Suijin to do, what is lost without it, and the way to change it.
/// Suijin only reads these states; the user grants and revokes them in System Settings.
struct PermissionsSection: View {
    @Environment(AppModel.self) private var model
    @State private var permissions: PermissionsModel?
    /// Set by tests and previews to show given states instead of the real system.
    private let injected: PermissionsModel?

    init(permissions: PermissionsModel? = nil) {
        injected = permissions
    }

    var body: some View {
        Section {
            if let permissions = injected ?? permissions, permissions.isLoaded {
                PermissionRow(
                    title: Text("Notifications"),
                    detail: Text("Banners when an agent waits for input or finishes."),
                    status: permissions.notifications, isOptional: false,
                    action: notificationsAction(permissions))
                PermissionRow(
                    title: Text("Background helper"),
                    detail: Text("Keeps sessions running after you quit Suijin."),
                    status: permissions.backgroundHelper, isOptional: false,
                    action: helperAction(permissions))
                PermissionRow(
                    title: Text("Full Disk Access"),
                    detail: Text("Optional. Lets agents read folders macOS protects without asking for each one."),
                    status: permissions.fullDiskAccess, isOptional: true,
                    action: permissions.fullDiskAccess == .allowed ? nil
                        : PermissionRow.Action(title: Text("Open System Settings")) { permissions.openFullDiskAccessSettings() })
            } else {
                LabeledContent {
                    ProgressView().controlSize(.small)
                } label: {
                    Text("Checking permissions…")
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Suijin never changes these itself. Grant or revoke them in System Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            guard injected == nil else { return }
            let live = PermissionsModel(sources: .live(usesHost: { [model] in model.runtimes.hostProblem == nil },
                                                       repairHelper: { [model] in await model.runtimes.repairHost() }))
            permissions = live
            await live.refresh()
        }
        // The user changes these in System Settings and comes back; read them again then.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard let permissions else { return }
            Task { await permissions.refresh() }
        }
    }

    private func notificationsAction(_ permissions: PermissionsModel) -> PermissionRow.Action? {
        switch permissions.notifications {
        case .allowed: nil
        case .notDetermined: PermissionRow.Action(title: Text("Allow…")) { Task { await permissions.requestNotifications() } }
        case .denied, .unknown, .broken:
            PermissionRow.Action(title: Text("Open System Settings")) { permissions.openNotificationSettings() }
        }
    }

    /// A helper that is allowed but does not start is repaired here; one that is off is turned on in Login Items.
    private func helperAction(_ permissions: PermissionsModel) -> PermissionRow.Action? {
        switch permissions.backgroundHelper {
        case .allowed: nil
        case .broken:
            PermissionRow.Action(title: Text("Repair"), isBusy: permissions.isRepairingHelper) {
                Task { await permissions.repairBackgroundHelper() }
            }
        case .denied, .notDetermined, .unknown:
            PermissionRow.Action(title: Text("Open Login Items")) { permissions.openLoginItems() }
        }
    }
}

/// One permission: its name, what it is for, its state and, when there is something to do, a button.
private struct PermissionRow: View {
    struct Action {
        let title: Text
        /// The work runs: the button is disabled and shows progress.
        var isBusy = false
        let perform: () -> Void
    }

    let title: Text
    let detail: Text
    let status: PermissionStatus
    /// An optional permission that is not granted is not a problem, so it is shown without a warning color.
    let isOptional: Bool
    let action: Action?

    var body: some View {
        LabeledContent {
            // The button drops below the state when the column is too narrow for both.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SuijinSpacing.m) { state; button }
                VStack(alignment: .trailing, spacing: SuijinSpacing.xs) { state; button }
            }
        } label: {
            title
            detail
            if case .unknown(let reason?) = status { Text(reason) }
            if case .broken(let reason) = status { Text(reason) }
        }
        .accessibilityElement(children: .contain)
    }

    private var state: some View {
        Label {
            stateText
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title): \(stateText)"))
    }

    @ViewBuilder private var button: some View {
        if let action {
            HStack(spacing: SuijinSpacing.s) {
                if action.isBusy { ProgressView().controlSize(.small) }
                Button(action: action.perform) { action.title }.fixedSize().disabled(action.isBusy)
            }
        }
    }

    private var stateText: Text {
        switch status {
        case .allowed: Text("Allowed")
        case .denied: Text("Not allowed")
        case .notDetermined: Text("Not asked")
        case .unknown: Text("Unknown")
        case .broken: Text("Not working")
        }
    }

    private var symbol: String {
        switch status {
        case .allowed: "checkmark.circle.fill"
        case .denied: isOptional ? "minus.circle" : "xmark.circle.fill"
        case .notDetermined, .unknown: "questionmark.circle"
        case .broken: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .allowed: .green
        case .denied: isOptional ? .secondary : SuijinColor.warning
        case .notDetermined, .unknown: .secondary
        case .broken: SuijinColor.warning
        }
    }
}

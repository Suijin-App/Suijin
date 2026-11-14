import AppKit
import ServiceManagement
import SuijinTerminal
import UserNotifications

/// What macOS says about one permission Suijin depends on.
enum PermissionStatus: Equatable {
    case allowed
    case denied
    /// The user was never asked (notifications only).
    case notDetermined
    /// The state could not be read; `reason` says why when there is something to say. Never shown as allowed.
    case unknown(reason: String?)
}

/// The system permissions Suijin depends on, as Settings shows them: read on demand, never changed by Suijin itself.
@MainActor
@Observable
final class PermissionsModel {
    /// Where each state comes from and how System Settings is opened; tests replace them.
    struct Sources {
        var notifications: @MainActor () async -> PermissionStatus
        var backgroundHelper: @MainActor () async -> PermissionStatus
        var fullDiskAccess: @MainActor () async -> PermissionStatus
        var requestNotifications: @MainActor () async -> Void
        /// Opens a System Settings pane; false when macOS did not take the URL.
        var open: @MainActor (URL) -> Bool
        var openLoginItems: @MainActor () -> Void
    }

    private(set) var notifications: PermissionStatus = .unknown(reason: nil)
    private(set) var backgroundHelper: PermissionStatus = .unknown(reason: nil)
    private(set) var fullDiskAccess: PermissionStatus = .unknown(reason: nil)
    /// False until the first read finished, so the section can show progress instead of "Unknown".
    private(set) var isLoaded = false
    @ObservationIgnored private let sources: Sources

    init(sources: Sources) {
        self.sources = sources
    }

    /// Reads every state again. Called when the section appears and whenever the app becomes active, because the
    /// user grants and revokes these in System Settings.
    func refresh() async {
        async let notifications = sources.notifications()
        async let helper = sources.backgroundHelper()
        async let disk = sources.fullDiskAccess()
        let read = await (notifications, helper, disk)
        (self.notifications, backgroundHelper, fullDiskAccess) = read
        isLoaded = true
    }

    /// Shows the system's own question; it appears only while the user was never asked.
    func requestNotifications() async {
        await sources.requestNotifications()
        await refresh()
    }

    func openNotificationSettings() {
        open(Self.notificationSettingsURL(bundleIdentifier: Bundle.main.bundleIdentifier))
    }

    func openFullDiskAccessSettings() {
        open(Self.fullDiskAccessSettingsURL)
    }

    func openLoginItems() {
        sources.openLoginItems()
    }

    /// Opens `url`, or System Settings itself when macOS does not know the pane (these URLs are not a public contract).
    private func open(_ url: URL?) {
        if let url, sources.open(url) { return }
        _ = sources.open(Self.systemSettingsURL)
    }

    static let systemSettingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
    static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")

    /// The Notifications pane, at this app's entry when the bundle identifier is known.
    static func notificationSettingsURL(bundleIdentifier: String?) -> URL? {
        let base = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        return URL(string: bundleIdentifier.map { "\(base)?id=\($0)" } ?? base)
    }

    // MARK: Mapping system answers

    static func status(for authorization: UNAuthorizationStatus?) -> PermissionStatus {
        switch authorization {
        case .authorized?, .provisional?, .ephemeral?: .allowed
        case .denied?: .denied
        case .notDetermined?: .notDetermined
        case nil: .unknown(reason: nil)
        @unknown default: .unknown(reason: nil)
        }
    }

    static func status(for approval: HostApproval) -> PermissionStatus {
        switch approval {
        case .enabled: .allowed
        case .requiresApproval: .denied
        case .notRegistered: .unknown(reason: String(localized: "The terminal host is not registered yet."))
        case .notFound: .unknown(reason: String(localized: "The terminal host is missing from the app."))
        }
    }

    static func status(for probe: FullDiskAccessProbe.Result) -> PermissionStatus {
        switch probe {
        case .granted: .allowed
        case .denied: .denied
        case .unknown: .unknown(reason: String(localized: "Suijin could not check this on your Mac."))
        }
    }
}

extension PermissionsModel.Sources {
    /// The real system. `usesHost` tells where sessions run: in the terminal host, or in the app when the host is
    /// unavailable; Full Disk Access is checked from that same place.
    static func live(usesHost: @escaping @MainActor () -> Bool) -> Self {
        Self(
            notifications: { PermissionsModel.status(for: await UserNotifier.shared.authorizationStatus()) },
            backgroundHelper: { PermissionsModel.status(for: PTYHostClient.shared.approval) },
            fullDiskAccess: {
                PermissionsModel.status(for: usesHost() ? await FullDiskAccessProbe.inHost() : FullDiskAccessProbe.inProcess())
            },
            requestNotifications: { await UserNotifier.shared.requestPermission() },
            open: { NSWorkspace.shared.open($0) },
            openLoginItems: { SMAppService.openSystemSettingsLoginItems() }
        )
    }
}

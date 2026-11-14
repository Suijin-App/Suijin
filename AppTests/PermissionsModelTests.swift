import Foundation
import SuijinTerminal
import Testing
import UserNotifications
@testable import Suijin

/// Settings › General › Permissions: how system answers become states, when they are read again, and where the
/// buttons lead. Nothing here asks the real system for a permission.
@MainActor
@Suite struct PermissionsModelTests {
    /// Sources that answer with fixed states and record what was asked of them.
    final class Fake {
        var notifications = PermissionStatus.allowed
        var helper = PermissionStatus.allowed
        var disk = PermissionStatus.allowed
        var reads = 0
        var requests = 0
        var opened: [URL] = []
        var loginItemsOpened = 0
        /// URLs macOS refuses, as an unknown System Settings pane would be.
        var refused: Set<URL> = []

        @MainActor var sources: PermissionsModel.Sources {
            PermissionsModel.Sources(
                notifications: { self.reads += 1; return self.notifications },
                backgroundHelper: { self.helper },
                fullDiskAccess: { self.disk },
                requestNotifications: { self.requests += 1; self.notifications = .allowed },
                open: { self.opened.append($0); return !self.refused.contains($0) },
                openLoginItems: { self.loginItemsOpened += 1 })
        }
    }

    @Test func notificationAnswersMapToStates() {
        #expect(PermissionsModel.status(for: UNAuthorizationStatus.authorized) == .allowed)
        #expect(PermissionsModel.status(for: UNAuthorizationStatus.provisional) == .allowed)
        #expect(PermissionsModel.status(for: UNAuthorizationStatus.denied) == .denied)
        #expect(PermissionsModel.status(for: UNAuthorizationStatus.notDetermined) == .notDetermined)
        // The test host never asks Notification Center, so there is no answer; that is not "allowed".
        #expect(PermissionsModel.status(for: UNAuthorizationStatus?.none) == .unknown(reason: nil))
    }

    @Test func helperAnswersMapToStates() {
        #expect(PermissionsModel.status(for: HostApproval.enabled) == .allowed)
        #expect(PermissionsModel.status(for: HostApproval.requiresApproval) == .denied)
        for unclear in [HostApproval.notRegistered, .notFound] {
            guard case .unknown(let reason) = PermissionsModel.status(for: unclear) else {
                Issue.record("\(unclear) must not read as allowed or denied")
                continue
            }
            #expect(reason?.isEmpty == false)
        }
    }

    @Test func fullDiskAccessAnswersMapToStates() {
        #expect(PermissionsModel.status(for: FullDiskAccessProbe.Result.granted) == .allowed)
        #expect(PermissionsModel.status(for: FullDiskAccessProbe.Result.denied) == .denied)
        guard case .unknown = PermissionsModel.status(for: FullDiskAccessProbe.Result.unknown) else {
            Issue.record("an inconclusive probe must stay unknown")
            return
        }
    }

    @Test func startsUnloadedAndReadsEveryState() async {
        let fake = Fake()
        fake.notifications = .notDetermined
        fake.helper = .denied
        fake.disk = .unknown(reason: "no folder")
        let model = PermissionsModel(sources: fake.sources)
        #expect(!model.isLoaded)
        await model.refresh()
        #expect(model.isLoaded)
        #expect(model.notifications == .notDetermined)
        #expect(model.backgroundHelper == .denied)
        #expect(model.fullDiskAccess == .unknown(reason: "no folder"))
    }

    @Test func refreshPicksUpAChangeMadeInSystemSettings() async {
        let fake = Fake()
        fake.disk = .denied
        let model = PermissionsModel(sources: fake.sources)
        await model.refresh()
        #expect(model.fullDiskAccess == .denied)
        fake.disk = .allowed
        await model.refresh()
        #expect(model.fullDiskAccess == .allowed)
        #expect(fake.reads == 2)
    }

    @Test func askingForNotificationsReadsTheAnswer() async {
        let fake = Fake()
        fake.notifications = .notDetermined
        let model = PermissionsModel(sources: fake.sources)
        await model.refresh()
        await model.requestNotifications()
        #expect(fake.requests == 1)
        #expect(model.notifications == .allowed)
    }

    @Test func buttonsOpenTheirPanes() async throws {
        let fake = Fake()
        let model = PermissionsModel(sources: fake.sources)
        model.openFullDiskAccessSettings()
        model.openNotificationSettings()
        model.openLoginItems()
        let disk = try #require(PermissionsModel.fullDiskAccessSettingsURL)
        #expect(fake.opened.first == disk)
        #expect(fake.opened.count == 2)
        #expect(fake.opened.last?.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.Notifications-Settings.extension") == true)
        #expect(fake.loginItemsOpened == 1)
    }

    @Test func anUnknownPaneFallsBackToSystemSettings() throws {
        let fake = Fake()
        let disk = try #require(PermissionsModel.fullDiskAccessSettingsURL)
        fake.refused = [disk]
        PermissionsModel(sources: fake.sources).openFullDiskAccessSettings()
        #expect(fake.opened == [disk, PermissionsModel.systemSettingsURL])
    }

    @Test func notificationPaneNamesTheApp() {
        #expect(PermissionsModel.notificationSettingsURL(bundleIdentifier: "com.example.app")?.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.example.app")
        #expect(PermissionsModel.notificationSettingsURL(bundleIdentifier: nil)?.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }
}

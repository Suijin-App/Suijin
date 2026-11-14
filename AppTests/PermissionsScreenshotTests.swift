import AppKit
import SuijinCore
import SwiftUI
import Testing
@testable import Suijin

/// Offscreen renders of Settings › General › Permissions in its states, narrow and wide, light and dark. Runs when
/// `SUIJIN_SCREENSHOTS` names an output folder; the images are reviewed by eye. The states are given, so nothing asks
/// the real system.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] != nil))
struct PermissionsScreenshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] ?? NSTemporaryDirectory())

    private func permissions(_ notifications: PermissionStatus, _ helper: PermissionStatus, _ disk: PermissionStatus) async -> PermissionsModel {
        let model = PermissionsModel(sources: PermissionsModel.Sources(
            notifications: { notifications }, backgroundHelper: { helper }, fullDiskAccess: { disk },
            requestNotifications: {}, open: { _ in true }, openLoginItems: {}))
        await model.refresh()
        return model
    }

    private func render(_ name: String, width: CGFloat, dark: Bool, _ permissions: PermissionsModel?, app: AppModel) throws {
        let size = CGSize(width: width, height: 420)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: Form { PermissionsSection(permissions: permissions) }
            .formStyle(.grouped).frame(width: size.width, height: size.height).environment(app))
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("permissions-\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
    }

    @Test func permissionStates() async throws {
        let app = AppModel(store: try SuijinStore.inMemory(), dataRoot: FileManager.default.temporaryDirectory)
        let states: [(String, PermissionsModel)] = [
            ("granted", await permissions(.allowed, .allowed, .allowed)),
            ("missing", await permissions(.notDetermined, .denied, .denied)),
            ("mixed", await permissions(.denied, .unknown(reason: "The terminal host is not registered yet."), .unknown(reason: "Suijin could not check this on your Mac."))),
            ("broken", await permissions(.allowed, PermissionsModel.status(for: .enabled, reachable: false, runsInApp: true), .allowed))
        ]
        for (name, model) in states {
            for width in [CGFloat(460), 760] {
                for dark in [false, true] { try render(name, width: width, dark: dark, model, app: app) }
            }
        }
    }
}

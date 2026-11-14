import Foundation
import Testing
@testable import SuijinTerminal

/// The Full Disk Access probe: how its answers are read, and that it never reports a guess as granted.
@Suite struct SystemAccessProbeTests {
    @Test func exitStatusesMapToResults() {
        #expect(FullDiskAccessProbe.result(forExitStatus: 0) == .granted)
        #expect(FullDiskAccessProbe.result(forExitStatus: 1) == .denied)
        // No folder found, a signal death, or a session whose status is unknown.
        for status in [Int32?.some(2), 127, 137, nil] {
            #expect(FullDiskAccessProbe.result(forExitStatus: status) == .unknown)
        }
    }

    @Test func aReadableFolderMeansGranted() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Mail"), withIntermediateDirectories: true)
        #expect(FullDiskAccessProbe.inProcess(home: home.path) == .granted)
    }

    @Test func aFolderThatCannotBeListedMeansDenied() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-probe-\(UUID().uuidString)")
        let folder = home.appendingPathComponent("Library/Safari")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: home)
        }
        #expect(FullDiskAccessProbe.inProcess(home: home.path) == .denied)
    }

    @Test func noFolderAtAllIsUnknown() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-probe-\(UUID().uuidString)")
        #expect(FullDiskAccessProbe.inProcess(home: home.path) == .unknown)
    }

    /// The script the terminal host runs gives the same three answers as the in-process probe.
    @Test func scriptAgreesWithTheInProcessProbe() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-probe-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.appendingPathComponent("Library/Safari").path)
            try? FileManager.default.removeItem(at: home)
        }
        func run() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", FullDiskAccessProbe.script, "sh"] + FullDiskAccessProbe.protectedFolders.map { home.path + "/" + $0 }
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(FullDiskAccessProbe.result(forExitStatus: try run()) == .unknown)
        let folder = home.appendingPathComponent("Library/Safari")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(FullDiskAccessProbe.result(forExitStatus: try run()) == .granted)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        #expect(FullDiskAccessProbe.result(forExitStatus: try run()) == .denied)
    }
}

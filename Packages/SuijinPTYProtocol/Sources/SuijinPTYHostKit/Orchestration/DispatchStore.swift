import Foundation
import SuijinPTYProtocol
import os

/// The broker's durable state: one JSON document per data root (`<dataRoot>/orchestration/state.json`, mode 600 in a
/// 700 directory), written atomically after every change. Only the helper writes it, so the app's database never has
/// two writers. Not thread-safe: the owning `Broker` confines it to its queue.
struct DispatchStore {
    private static let logger = Logger(subsystem: "com.tekmium.suijin.ptyhost", category: "orchestration")
    /// Delivered messages and settled dispatches are kept this long, so the inbox and the inspector show recent work.
    static let retention: TimeInterval = 14 * 24 * 3600

    struct Document: Codable {
        var version = 1
        var snapshot = OrchestrationSnapshot()
    }

    /// nil keeps everything in memory (tests, and a closed broker).
    private(set) var fileURL: URL?
    private(set) var state = OrchestrationSnapshot()

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Reads the file; a missing file is an empty state, an unreadable one is moved aside and replaced.
    mutating func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            state = try OrchestrationCoding.decoder.decode(Document.self, from: data).snapshot
        } catch {
            Self.logger.error("orchestration state unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            let aside = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
    }

    mutating func update(_ change: (inout OrchestrationSnapshot) -> Void) {
        change(&state)
        save()
    }

    /// Keeps later changes in memory only (the owning broker closed).
    mutating func stopSaving() {
        fileURL = nil
    }

    /// Drops settled work older than `retention`.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let oldDispatches = Set(state.dispatches.filter { $0.status.isSettled && $0.updatedAt < cutoff }.map(\.id))
        guard !oldDispatches.isEmpty else { return }
        update { state in
            state.dispatches.removeAll { oldDispatches.contains($0.id) }
            state.messages.removeAll { oldDispatches.contains($0.dispatchID) && $0.status != .pending }
            let liveTasks = Set(state.dispatches.map(\.taskID))
            state.tasks.removeAll { !liveTasks.contains($0.id) }
            let liveRuns = Set(state.dispatches.map(\.runID))
            state.runs.removeAll { !liveRuns.contains($0.id) }
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try OrchestrationCoding.encoder.encode(Document(snapshot: state))
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Self.logger.error("cannot save orchestration state: \(error.localizedDescription, privacy: .public)")
        }
    }
}

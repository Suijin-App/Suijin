import Foundation

extension AppModel {
    private static let sessionOrderKey = "tabs.sessionOrder"

    /// The saved session tab order of every context, from user defaults.
    static func savedSessionOrder() -> [SessionContext: [UUID]] {
        guard let saved = UserDefaults.standard.dictionary(forKey: sessionOrderKey) as? [String: [String]] else { return [:] }
        var order: [SessionContext: [UUID]] = [:]
        for (key, ids) in saved {
            guard let context = SessionContext(storageValue: key) else { continue }
            order[context] = ids.compactMap(UUID.init(uuidString:))
        }
        return order
    }

    /// Moves a dragged tab to the place of `target` in `context`: sessions among sessions, files among files (the
    /// Changes tab stays between them). Dropping a tab on itself or across kinds does nothing.
    func moveTab(_ dragged: DetailTab, onto target: DetailTab, in context: SessionContext) {
        guard dragged != target else { return }
        switch (dragged, target) {
        case let (.session(moving), .session(destination)):
            var ids = tabSessions(in: context).map(\.id)
            guard let from = ids.firstIndex(of: moving), let to = ids.firstIndex(of: destination) else { return }
            ids.remove(at: from)
            ids.insert(moving, at: to)
            sessionOrder[context] = ids
            saveSessionOrder()
        case let (.file(moving), .file(destination)):
            var paths = openFiles[context] ?? []
            guard let from = paths.firstIndex(of: moving), let to = paths.firstIndex(of: destination) else { return }
            paths.remove(at: from)
            paths.insert(moving, at: to)
            openFiles[context] = paths
        default:
            break
        }
    }

    private func saveSessionOrder() {
        let live = Set(sessions.map(\.id))
        var saved: [String: [String]] = [:]
        for (context, ids) in sessionOrder {
            let kept = ids.filter(live.contains)
            if !kept.isEmpty { saved[context.storageValue] = kept.map(\.uuidString) }
        }
        UserDefaults.standard.set(saved, forKey: Self.sessionOrderKey)
    }
}

extension DetailTab {
    /// The tab as a drag payload: "session:<uuid>" or "file:<path>"; the Changes tab is not draggable.
    var dragPayload: String? {
        switch self {
        case .session(let id): "session:\(id.uuidString)"
        case .file(let path): "file:\(path)"
        case .changes: nil
        }
    }

    init?(dragPayload: String) {
        if dragPayload.hasPrefix("session:"), let id = UUID(uuidString: String(dragPayload.dropFirst(8))) {
            self = .session(id)
        } else if dragPayload.hasPrefix("file:") {
            self = .file(String(dragPayload.dropFirst(5)))
        } else {
            return nil
        }
    }
}

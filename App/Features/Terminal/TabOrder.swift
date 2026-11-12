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

    /// Moves a dragged tab to the place of `target` in `context`: session and split tabs among themselves, files
    /// among files (the Changes tab stays between them). Dropping a tab on itself or across kinds does nothing.
    func moveTab(_ dragged: DetailTab, onto target: DetailTab, in context: SessionContext) {
        guard dragged != target else { return }
        switch (dragged, target) {
        case (.session, .session), (.session, .panes), (.panes, .session), (.panes, .panes):
            // Plain and split tabs order together, by their order keys.
            var ids = sessionTabs(in: context).compactMap(\.orderKey)
            guard let moving = dragged.orderKey, let destination = target.orderKey,
                  let from = ids.firstIndex(of: moving), let to = ids.firstIndex(of: destination) else { return }
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

    /// Stores the tab order of every context; ids of sessions and split tabs that are gone are left out.
    func saveSessionOrder() {
        let live = Set(sessions.map(\.id)).union(paneLayouts.keys)
        var saved: [String: [String]] = [:]
        for (context, ids) in sessionOrder {
            let kept = ids.filter(live.contains)
            if !kept.isEmpty { saved[context.storageValue] = kept.map(\.uuidString) }
        }
        UserDefaults.standard.set(saved, forKey: Self.sessionOrderKey)
    }
}

extension DetailTab {
    /// The tab as a drag payload: "session:<uuid>", "panes:<uuid>" or "file:<path>"; the Changes tab is not
    /// draggable.
    var dragPayload: String? {
        switch self {
        case .session(let id): "session:\(id.uuidString)"
        case .panes(let id): "panes:\(id.uuidString)"
        case .file(let path): "file:\(path)"
        case .changes: nil
        }
    }

    init?(dragPayload: String) {
        if dragPayload.hasPrefix("session:"), let id = UUID(uuidString: String(dragPayload.dropFirst(8))) {
            self = .session(id)
        } else if dragPayload.hasPrefix("panes:"), let id = UUID(uuidString: String(dragPayload.dropFirst(6))) {
            self = .panes(id)
        } else if dragPayload.hasPrefix("file:") {
            self = .file(String(dragPayload.dropFirst(5)))
        } else {
            return nil
        }
    }
}

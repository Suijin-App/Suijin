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

    private static let tabOrderKey = "tabs.order"

    /// The saved order of every context's tabs, from user defaults.
    static func savedTabOrder() -> [SessionContext: [String]] {
        guard let saved = UserDefaults.standard.dictionary(forKey: tabOrderKey) as? [String: [String]] else { return [:] }
        var order: [SessionContext: [String]] = [:]
        for (key, payloads) in saved {
            guard let context = SessionContext(storageValue: key) else { continue }
            order[context] = payloads
        }
        return order
    }

    /// `natural` (sessions, then Changes, then files) in the dragged `order`: listed tabs by their place in it, and
    /// each tab not listed (a new session or file) right after the tab it follows in `natural`, so it opens beside
    /// its kind.
    static func arrange(_ natural: [DetailTab], by order: [String]) -> [DetailTab] {
        guard !order.isEmpty else { return natural }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var result = natural.filter { rank[$0.dragPayload] != nil }
            .sorted { rank[$0.dragPayload, default: 0] < rank[$1.dragPayload, default: 0] }
        for (index, tab) in natural.enumerated() where rank[tab.dragPayload] == nil {
            let after = index == 0 ? nil : result.firstIndex(of: natural[index - 1])
            result.insert(tab, at: after.map { $0 + 1 } ?? 0)
        }
        return result
    }

    /// Moves a dragged tab to the place of `target` in `context`. Any tab can go anywhere (sessions, split tabs,
    /// Changes and files mix); dropping a tab on itself does nothing.
    func moveTab(_ dragged: DetailTab, onto target: DetailTab, in context: SessionContext) {
        var tabs = tabList(in: context)
        guard dragged != target, let from = tabs.firstIndex(of: dragged), let to = tabs.firstIndex(of: target) else { return }
        tabs.remove(at: from)
        tabs.insert(dragged, at: to)
        // Each kind's own order follows, for what lists only that kind (sidebar, ⌘-number of sessions).
        sessionOrder[context] = tabs.compactMap(\.orderKey)
        saveSessionOrder()
        openFiles[context] = tabs.compactMap { if case .file(let path) = $0 { path } else { nil } }
        tabOrder[context] = tabs.map(\.dragPayload)
        saveTabOrder()
    }

    /// Stores the tab order of every context.
    func saveTabOrder() {
        var saved: [String: [String]] = [:]
        for (context, payloads) in tabOrder where !payloads.isEmpty { saved[context.storageValue] = payloads }
        UserDefaults.standard.set(saved, forKey: Self.tabOrderKey)
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
    /// The tab as a drag payload: "session:<uuid>", "panes:<uuid>", "changes" or "file:<path>".
    var dragPayload: String {
        switch self {
        case .session(let id): "session:\(id.uuidString)"
        case .panes(let id): "panes:\(id.uuidString)"
        case .file(let path): "file:\(path)"
        case .changes: "changes"
        }
    }

    init?(dragPayload: String) {
        if dragPayload.hasPrefix("session:"), let id = UUID(uuidString: String(dragPayload.dropFirst(8))) {
            self = .session(id)
        } else if dragPayload.hasPrefix("panes:"), let id = UUID(uuidString: String(dragPayload.dropFirst(6))) {
            self = .panes(id)
        } else if dragPayload == "changes" {
            self = .changes
        } else if dragPayload.hasPrefix("file:") {
            self = .file(String(dragPayload.dropFirst(5)))
        } else {
            return nil
        }
    }
}

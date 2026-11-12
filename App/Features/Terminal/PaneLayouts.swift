import AppKit
import SevindaCore
import os

private let logger = Logger(subsystem: "com.tekmium.mercury", category: "panes")

/// Split tabs: a tab showing two to ten sessions as panes, arranged by a `PaneLayout` (SevindaCore). A tab with one
/// session is a plain `.session` tab and has no layout; adding a pane turns it into a `.panes` tab in the same place,
/// and the last pane but one closing turns it back.
///
/// Every change goes through these functions: they keep `paneLayouts`, the tab order, the selection and the stored
/// layout in step. Title-bar buttons, menus, shortcuts and drag and drop call them.
extension AppModel {
    // MARK: Reading

    /// The split tab a session is a pane of.
    func layout(containing session: UUID) -> PaneLayout? {
        paneIndex[session].flatMap { paneLayouts[$0] }
    }

    /// The tab that shows a session: its split tab, or its own.
    func tab(of session: UUID) -> DetailTab {
        layout(containing: session).map { .panes($0.id) } ?? .session(session)
    }

    /// The sessions a tab shows, in reading order; empty for Changes and file tabs.
    func panes(of tab: DetailTab) -> [UUID] {
        switch tab {
        case .session(let id): [id]
        case .panes(let id): paneLayouts[id]?.panes ?? []
        case .changes, .file: []
        }
    }

    /// The panes on screen in the context's selected tab: one when a pane is zoomed.
    func visiblePanes(in context: SessionContext) -> [UUID] {
        guard let tab = currentTab(in: context) else { return [] }
        if case .panes(let id) = tab, let zoomed = paneLayouts[id]?.zoomed { return [zoomed] }
        return panes(of: tab)
    }

    /// Whether the user is looking at this session right now (the app in front, its context and tab selected).
    func isShowing(_ session: UUID, in context: SessionContext) -> Bool {
        NSApp.isActive && selection == context && visiblePanes(in: context).contains(session)
    }

    /// Whether another pane fits beside `session`: a plain tab always has room, a split tab up to
    /// `PaneLayout.maxPanes`.
    func canAddPane(beside session: UUID) -> Bool {
        !(layout(containing: session)?.isFull ?? false)
    }

    // MARK: Adding panes

    /// Starts a session and shows it as a pane beside `target` (the selected tab's focused pane when nil) on `edge`.
    /// `agent` nil runs the same agent with the same account as the target pane. The new pane takes the keyboard.
    /// Returns the new session, nil when nothing started (no session tab selected, the tab is full, the start failed).
    @discardableResult
    func newPane(in context: SessionContext, beside target: UUID? = nil, edge: PaneEdge, agent: AgentKind? = nil,
                 accountID: UUID? = nil) async -> UUID? {
        guard let target = target ?? activeSession(in: context),
              let record = sessions.first(where: { $0.id == target }), self.context(of: record) == context else { return nil }
        guard canAddPane(beside: target) else {
            presentedError = PresentedError(title: String(localized: "Could not add a pane"),
                                            message: String(localized: "A tab holds up to \(PaneLayout.maxPanes) panes."))
            return nil
        }
        let agent = agent ?? record.agent
        let account = agent == record.agent ? (accountID ?? record.accountID) : accountID
        guard let id = await runtimes.start(in: context, agent: agent, accountID: account, prompt: nil, select: false) else { return nil }
        do {
            try insertPane(id, beside: target, edge: edge)
        } catch {
            // The target tab closed or filled up while the session started: it stays a tab of its own.
            logger.info("New pane shown as its own tab: \(String(describing: error), privacy: .public)")
            selectedTab[context] = .session(id)
        }
        return id
    }

    /// Shows the session `pane` (already running, in the same context) beside `target` on `edge`. A session that was a
    /// tab of its own stops being one; `target`'s plain tab becomes a split tab in its place. Selects the tab and
    /// focuses the pane.
    func insertPane(_ pane: UUID, beside target: UUID, edge: PaneEdge) throws {
        guard pane != target else { throw PaneLayoutError.samePane }
        guard let targetRecord = sessions.first(where: { $0.id == target }),
              let paneRecord = sessions.first(where: { $0.id == pane }),
              context(of: targetRecord) == context(of: paneRecord) else { throw PaneLayoutError.unknownPane }
        guard layout(containing: pane) == nil else { throw PaneLayoutError.duplicatePane }
        let context = context(of: targetRecord)
        if let existing = layout(containing: target) {
            commit(try existing.inserting(pane, beside: target, edge: edge))
        } else {
            let layout = try PaneLayout(pane: target).inserting(pane, beside: target, edge: edge)
            commit(layout)
            replaceTab(.session(target), with: .panes(layout.id), in: context)
        }
        removeFromOrder(pane, in: context)
        if let layoutID = paneIndex[pane] { selectedTab[context] = .panes(layoutID) }
    }

    // MARK: Rearranging

    /// Moves `pane` beside `target` (`.edge`) or swaps the two (`.center`); both are panes of the same split tab. The
    /// moved pane keeps the keyboard.
    func movePane(_ pane: UUID, to target: UUID, placement: PanePlacement) throws {
        guard let layout = layout(containing: pane), layout.contains(target) else { throw PaneLayoutError.unknownPane }
        commit(try layout.moving(pane, to: target, placement: placement))
    }

    /// Swaps `pane` with its neighbor on `edge`; nothing at the tab's edge. Returns whether it moved.
    @discardableResult
    func movePane(_ pane: UUID, toward edge: PaneEdge) -> Bool {
        guard let layout = layout(containing: pane), let neighbor = layout.neighbor(of: pane, toward: edge),
              let moved = try? layout.moving(pane, to: neighbor, placement: .center) else { return false }
        commit(moved)
        return true
    }

    /// Takes a pane out of its split tab into a tab of its own, right after the split tab, and selects it.
    func movePaneToNewTab(_ pane: UUID) {
        guard let layout = layout(containing: pane), let record = sessions.first(where: { $0.id == pane }) else { return }
        let context = context(of: record)
        let remaining = try? layout.removing(pane)
        apply(remaining, replacing: layout, in: context)
        var order = sessionTabs(in: context).compactMap(\.orderKey).filter { $0 != pane }
        let anchor = remaining.map { $0.paneCount > 1 ? $0.id : $0.panes[0] } ?? pane
        order.insert(pane, at: (order.firstIndex(of: anchor) ?? order.count - 1) + 1)
        sessionOrder[context] = order
        saveSessionOrder()
        selectedTab[context] = .session(pane)
    }

    /// Every split of the tab divides its room equally.
    func equalizePanes(_ layoutID: UUID) {
        guard let layout = paneLayouts[layoutID] else { return }
        commit(layout.equalized())
    }

    /// Shows the pane alone in its tab, or restores the tab when it already is.
    func toggleZoom(_ pane: UUID) {
        guard let layout = layout(containing: pane), let zoomed = try? layout.togglingZoom(pane) else { return }
        commit(zoomed)
    }

    /// New shares of the split at `path` (child indices from the root) after a divider moved; stored after a pause.
    func setPaneFractions(_ fractions: [Double], at path: [Int], in layoutID: UUID) {
        guard let layout = paneLayouts[layoutID] else { return }
        let resized = layout.settingFractions(fractions, at: path)
        guard resized != layout else { return }
        commit(resized, debounced: true)
    }

    // MARK: Focus

    /// Marks a pane as its tab's focused pane. The one entry point: the pane's terminal reports here whenever it
    /// becomes first responder, however the keyboard got there; the pane container then gives that terminal the
    /// keyboard when the model moves the focus. Nothing for a plain tab.
    func focusPane(_ pane: UUID) {
        guard let layout = layout(containing: pane), layout.focused != pane,
              let focused = try? layout.focusing(pane) else { return }
        commit(focused, debounced: true)
    }

    /// Moves the focus to the pane next to the selected tab's focused pane on `edge`. Returns whether it moved.
    @discardableResult
    func focusNeighborPane(in context: SessionContext, toward edge: PaneEdge) -> Bool {
        guard case .panes(let id)? = currentTab(in: context), let layout = paneLayouts[id], layout.zoomed == nil,
              let neighbor = layout.neighbor(of: layout.focused, toward: edge) else { return false }
        focusPane(neighbor)
        return true
    }

    // MARK: Persistence

    /// Brings back the stored split tabs at launch: panes whose session is gone (or now runs elsewhere) are dropped,
    /// and a layout left with one pane is deleted.
    func restorePaneLayouts() async {
        let records: [PaneLayoutRecord]
        do {
            records = try await io { try $0.paneLayouts() }
        } catch {
            logger.error("Could not load pane layouts: \(error.localizedDescription, privacy: .public)")
            return
        }
        var restored: [UUID: PaneLayout] = [:]
        var claimed = Set<UUID>()
        for record in records {
            let owned = Set(sessions.filter { $0.workspaceID == record.workspaceID && $0.worktreeID == record.worktreeID }.map(\.id))
            let layout = record.layout.retaining(owned.subtracting(claimed))
            if let layout, layout.paneCount > 1 {
                restored[layout.id] = layout
                claimed.formUnion(layout.panes)
                if layout != record.layout { persist(layout) }
            } else {
                try? await io { try $0.deletePaneLayout(id: record.id) }
            }
        }
        paneLayouts = restored
    }

    /// Drops panes whose session is gone; called whenever sessions are removed.
    func reconcilePaneLayouts() {
        let live = Set(sessions.map(\.id))
        for layout in paneLayouts.values where !layout.panes.allSatisfy(live.contains) {
            let context = layout.panes.lazy.compactMap { id in self.sessions.first { $0.id == id } }.first.map(context(of:))
            guard let context else {
                // No pane is left at all.
                drop(layout)
                continue
            }
            apply(layout.retaining(live), replacing: layout, in: context)
        }
    }

    // MARK: Internals

    /// Replaces a layout in memory and stores it (after a pause when `debounced`, for changes that come in bursts).
    private func commit(_ layout: PaneLayout, debounced: Bool = false) {
        paneLayouts[layout.id] = layout
        if debounced {
            layoutSaves[layout.id]?.cancel()
            layoutSaves[layout.id] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, let current = self.paneLayouts[layout.id] else { return }
                self.layoutSaves[layout.id] = nil
                self.persist(current)
            }
        } else {
            layoutSaves[layout.id]?.cancel()
            layoutSaves[layout.id] = nil
            persist(layout)
        }
    }

    private func persist(_ layout: PaneLayout) {
        guard let first = layout.panes.lazy.compactMap({ id in self.sessions.first { $0.id == id } }).first else { return }
        let record = PaneLayoutRecord(workspaceID: first.workspaceID, worktreeID: first.worktreeID, layout: layout)
        let store = store
        Task.detached {
            do { try store.save(record) } catch {
                logger.error("Could not save a pane layout: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Puts what is left of a split tab in its place: the layout itself while it has two panes or more, else a plain
    /// tab of the last pane (or nothing).
    private func apply(_ remaining: PaneLayout?, replacing layout: PaneLayout, in context: SessionContext) {
        if let remaining, remaining.paneCount > 1 {
            commit(remaining)
            return
        }
        drop(layout)
        if let last = remaining?.panes.first {
            replaceTab(.panes(layout.id), with: .session(last), in: context)
        } else {
            for (context, tab) in selectedTab where tab == .panes(layout.id) { selectedTab[context] = nil }
        }
    }

    private func drop(_ layout: PaneLayout) {
        layoutSaves[layout.id]?.cancel()
        layoutSaves[layout.id] = nil
        paneLayouts[layout.id] = nil
        let store = store
        Task.detached { try? store.deletePaneLayout(id: layout.id) }
    }

    /// A tab changed identity (a plain tab became a split tab or back): it keeps its place and its selection.
    private func replaceTab(_ old: DetailTab, with new: DetailTab, in context: SessionContext) {
        for (context, tab) in selectedTab where tab == old { selectedTab[context] = new }
        if var order = sessionOrder[context], let oldKey = old.orderKey, let newKey = new.orderKey,
           let index = order.firstIndex(of: oldKey) {
            order[index] = newKey
            sessionOrder[context] = order
            saveSessionOrder()
        }
    }

    private func removeFromOrder(_ session: UUID, in context: SessionContext) {
        guard var order = sessionOrder[context], let index = order.firstIndex(of: session) else { return }
        order.remove(at: index)
        sessionOrder[context] = order
        saveSessionOrder()
    }

    /// The selection as the setter of `selectedTab` stores it: a pane's `.session` becomes its split tab, and the
    /// pane takes the focus.
    func normalizedSelection(_ selection: [SessionContext: DetailTab]) -> [SessionContext: DetailTab] {
        var result = selection
        for (context, tab) in selection {
            guard case .session(let id) = tab, let layout = layout(containing: id) else { continue }
            result[context] = .panes(layout.id)
            focusPane(id)
        }
        return result
    }
}

extension DetailTab {
    /// The id a session or split tab is ordered by (`AppModel.sessionOrder`).
    var orderKey: UUID? {
        switch self {
        case .session(let id), .panes(let id): id
        case .changes, .file: nil
        }
    }
}

#if DEBUG
extension AppModel {
    /// Screenshot runs: `-MercuryDemoPanes <n>` opens a shell in the selected context with n panes (two rows when
    /// n > 3), so the pane container can be captured in a real window.
    func openDemoPanesIfRequested() async {
        let count = min(UserDefaults.standard.integer(forKey: "MercuryDemoPanes"), PaneLayout.maxPanes)
        guard count > 0, let context = selection,
              let first = await runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil) else { return }
        var top = [first]
        let columns = count > 3 ? (count + 1) / 2 : count
        while top.count < columns, let next = await newPane(in: context, beside: top.last, edge: .right) { top.append(next) }
        var added = top.count
        for pane in top where added < count {
            if await newPane(in: context, beside: pane, edge: .bottom) != nil { added += 1 }
        }
        if let layout = layout(containing: first) { equalizePanes(layout.id) }
        focusPane(first)
    }
}
#endif

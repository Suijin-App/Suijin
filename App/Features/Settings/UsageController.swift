import Foundation
import MercuryCore
import MercuryUsage
import Observation

/// Which providers the usage page sums up.
enum UsageScope: String, CaseIterable, Identifiable {
    case overview, claude, codex

    var id: Self { self }

    /// The provider filter for `UsageSnapshot.summary`; nil sums every provider.
    var provider: UsageProvider? {
        switch self {
        case .overview: nil
        case .claude: .claude
        case .codex: .codex
        }
    }
}

/// The time range of the usage totals. The daily heatmap ignores it and always shows the last six weeks.
enum UsageRange: String, CaseIterable, Identifiable {
    case sevenDays, thirtyDays, allTime

    var id: Self { self }

    /// Number of local calendar days the range covers, today included; nil for all time.
    var days: Int? {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .allTime: nil
        }
    }

    /// The first day in range (its start of day), or nil for all time.
    func since(now: Date, calendar: Calendar = .current) -> Date? {
        guard let days else { return nil }
        return calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))
    }
}

/// State of Settings → Stats & Usage for the app's lifetime: one `UsageStore` (so the incremental checkpoints stay in
/// memory between visits), the last usage snapshot, Mercury's own counters, and the selected scope and range.
///
/// Nothing runs in the background on its own: the page calls `pageAppeared()` to show the cache and start one
/// refresh, `refresh()` from its button, and `pageDisappeared()` to cancel a scan still running when it closes.
@Observable
@MainActor
final class UsageController {
    /// The usage last read, from the cache first and then from each refresh; nil until either is available.
    private(set) var snapshot: UsageSnapshot?
    /// Mercury's own counters; nil until loaded.
    private(set) var stats: MercuryStats?
    /// 0…1 while a refresh runs, nil otherwise.
    private(set) var progress: Double?
    /// Why the last refresh failed (already localized); cleared when one succeeds.
    private(set) var refreshError: String?
    /// Why Mercury's counters could not be read (already localized).
    private(set) var statsError: String?
    var scope: UsageScope = .overview
    var range: UsageRange = .thirtyDays

    var isRefreshing: Bool { progress != nil }

    @ObservationIgnored private let store: UsageStore
    @ObservationIgnored private let sources: @MainActor () -> UsageSourceSet
    @ObservationIgnored private let loadStats: @MainActor () async throws -> MercuryStats
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Bumped whenever a refresh starts or is abandoned, so late progress reports of an old one are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cacheLoaded = false

    init(
        store: UsageStore, sources: @escaping @MainActor () -> UsageSourceSet,
        loadStats: @escaping @MainActor () async throws -> MercuryStats
    ) {
        self.store = store
        self.sources = sources
        self.loadStats = loadStats
    }

    /// The live controller: the cache under the data root, the user's own logs plus every managed account's home.
    convenience init(model: AppModel) {
        let cacheURL = model.dataRoot.appendingPathComponent("usage", isDirectory: true)
            .appendingPathComponent("cache.json")
        self.init(
            store: UsageStore(cacheURL: cacheURL, sources: Self.sources(for: model.accounts)),
            sources: { [weak model] in Self.sources(for: model?.accounts ?? []) },
            loadStats: { [weak model] in
                guard let model else { throw CancellationError() }
                return try await model.io { try $0.mercuryStats() }
            })
    }

    /// The standard log folders plus the homes of the managed accounts, per provider.
    static func sources(for accounts: [ManagedAccountRecord]) -> UsageSourceSet {
        func homes(_ provider: AccountProvider) -> [URL] {
            accounts.filter { $0.provider == provider }.map { URL(fileURLWithPath: $0.homePath, isDirectory: true) }
        }
        #if DEBUG
        // Screenshot runs read demo logs instead of the user's own: `-MercuryUsageHome <dir>` stands in for the home
        // folder, and CLAUDE_CONFIG_DIR / CODEX_HOME from the environment are ignored.
        if let home = UserDefaults.standard.string(forKey: "MercuryUsageHome") {
            return UsageSourceSet.standard(environment: [:], homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
                                           managedClaudeHomes: homes(.claude), managedCodexHomes: homes(.codex))
        }
        #endif
        return UsageSourceSet.standard(managedClaudeHomes: homes(.claude), managedCodexHomes: homes(.codex))
    }

    /// Summary for the selected scope and range.
    func summary(now: Date = Date()) -> MercuryUsage.UsageSummary? {
        snapshot?.summary(provider: scope.provider, since: range.since(now: now))
    }

    // MARK: Page lifecycle

    /// Shows the cached usage at once, reloads Mercury's counters and starts a refresh.
    func pageAppeared() {
        Task { await reloadStats() }
        refresh()
    }

    /// Cancels a refresh still running; what it merged so far stays in the store's cache.
    func pageDisappeared() {
        refreshTask?.cancel()
        refreshTask = nil
        generation += 1
        progress = nil
    }

    /// Starts a refresh unless one is running; the returned task finishes when it is done.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        if let refreshTask { return refreshTask }
        generation += 1
        let current = generation
        progress = 0
        let task = Task { await self.performRefresh(generation: current) }
        refreshTask = task
        return task
    }

    func reloadStats() async {
        do {
            stats = try await loadStats()
            statsError = nil
        } catch is CancellationError {
            return
        } catch {
            statsError = error.localizedDescription
        }
    }

    /// Shows the cache file's usage while nothing newer is shown; reads it once per app launch.
    func showCachedUsage() async {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        if snapshot == nil, let cached = await store.cachedSnapshot() { snapshot = cached }
    }

    private func performRefresh(generation current: Int) async {
        let store = store
        await showCachedUsage()
        await store.updateSources(sources())
        do {
            let result = try await store.refresh { [weak self] fraction in
                Task { @MainActor in self?.report(fraction, generation: current) }
            }
            guard current == generation else { return }
            snapshot = result
            refreshError = nil
        } catch {
            // A cancelled scan or a cache that could not be saved still leaves valid usage in the store's memory.
            if let partial = await store.cachedSnapshot(), current == generation || snapshot == nil { snapshot = partial }
            if current == generation, !(error is CancellationError) { refreshError = error.localizedDescription }
        }
        if current == generation {
            progress = nil
            refreshTask = nil
        }
    }

    private func report(_ fraction: Double, generation current: Int) {
        guard current == generation, refreshTask != nil else { return }
        // Progress only moves forward: reports hop to the main actor in separate tasks and may arrive out of order.
        progress = max(progress ?? 0, min(1, fraction))
    }
}

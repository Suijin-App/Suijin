import Foundation
import Synchronization

/// Estimated cost at API list prices, in US dollars per million tokens.
///
/// Source: Orca (MIT) `src/main/claude-usage/claude-model-pricing.ts` and `src/main/codex-usage/codex-model-pricing.ts`,
/// which follow Anthropic's and OpenAI's published API prices; copied on 2026-11-12. This is not what a subscription
/// bills. An unknown model has no price (`nil`, shown as "n/a"); add it here explicitly rather than guessing.
/// Changing any rate requires bumping `revision`, which makes the next refresh rescan every log.
enum ModelPricing {
    static let revision = "2026-11-12"

    /// Cost of one request (Claude) or one token-count event (Codex). Long-context rates apply to the whole request.
    static func cost(provider: UsageProvider, model: String, tokens: UsageTokens, cacheWrite1h: Int, longContext: Bool)
        -> Double?
    {
        switch provider {
        case .claude:
            guard let pricing = claudePricing(model) else { return nil }
            let prompt = tokens.input + tokens.cacheRead + tokens.cacheWrite
            let rates = pricing.longContext.flatMap { prompt > $0.threshold ? $0.rates : nil } ?? pricing.rates
            return rates.price(tokens, cacheWrite1h: cacheWrite1h)
        case .codex:
            guard let pricing = codexPricing(model) else { return nil }
            let rates = longContext ? (pricing.longContext ?? pricing.rates) : pricing.rates
            return rates.price(tokens)
        }
    }

    // MARK: Claude

    struct ClaudeRates: Sendable {
        let input: Double
        let output: Double
        let cacheRead: Double
        /// Five-minute cache writes.
        let cacheWrite: Double
        let cacheWrite1h: Double

        func price(_ tokens: UsageTokens, cacheWrite1h write1h: Int) -> Double {
            let longWrites = min(max(write1h, 0), tokens.cacheWrite)
            let sum =
                Double(tokens.input) * input + Double(tokens.output) * output + Double(tokens.cacheRead) * cacheRead
                + Double(tokens.cacheWrite - longWrites) * cacheWrite + Double(longWrites) * cacheWrite1h
            return sum / 1_000_000
        }
    }

    struct ClaudePricing: Sendable {
        let rates: ClaudeRates
        /// Requests whose prompt (input + cache read + cache write) exceeds `threshold` bill entirely at `rates`.
        let longContext: (threshold: Int, rates: ClaudeRates)?
    }

    private static func claude(
        _ input: Double, _ output: Double, _ cacheRead: Double, _ cacheWrite: Double, _ cacheWrite1h: Double,
        longContext: (Int, ClaudeRates)? = nil
    ) -> ClaudePricing {
        ClaudePricing(
            rates: ClaudeRates(
                input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
                cacheWrite1h: cacheWrite1h),
            longContext: longContext.map { (threshold: $0.0, rates: $0.1) })
    }

    private static let sonnet4LongContext = (
        200_000, ClaudeRates(input: 6, output: 22.5, cacheRead: 0.6, cacheWrite: 7.5, cacheWrite1h: 12)
    )

    static let claudeTable: [String: ClaudePricing] = {
        let fable52 = claude(8, 40, 0.2, 10, 16)
        let fable51 = claude(10, 50, 0.25, 12.5, 20)
        let fable5 = claude(10, 50, 1, 12.5, 20)
        let opus45 = claude(5, 25, 0.5, 6.25, 10)
        let opus4 = claude(15, 75, 1.5, 18.75, 30)
        let sonnet3 = claude(3, 15, 0.3, 3.75, 6)
        return [
            // Mythos models are billed at their Fable counterparts' rates.
            "claude-fable-5-2": fable52, "claude-mythos-5-2": fable52,
            "claude-fable-5-1": fable51, "claude-mythos-5-1": fable51,
            "claude-fable-5": fable5, "claude-mythos-5": fable5,
            "claude-opus-5-5": claude(4, 20, 0.2, 5, 8),
            "claude-opus-5": opus45,
            "claude-sonnet-5-5": claude(2, 10, 0.1, 2.5, 4),
            "claude-sonnet-5": claude(2, 10, 0.2, 2.5, 4),
            "claude-opus-4-8": opus45, "claude-opus-4-7": opus45, "claude-opus-4-6": opus45, "claude-opus-4-5": opus45,
            "claude-opus-4-1": opus4, "claude-opus-4": opus4,
            // Sonnet 4.6 keeps standard rates across its full 1M context window.
            "claude-sonnet-4-6": sonnet3,
            "claude-sonnet-4-5": claude(3, 15, 0.3, 3.75, 6, longContext: sonnet4LongContext),
            "claude-sonnet-4": claude(3, 15, 0.3, 3.75, 6, longContext: sonnet4LongContext),
            "claude-sonnet-3-7": sonnet3, "claude-sonnet-3-5": sonnet3,
            "claude-haiku-5-5": claude(
                0.1, 0.5, 0.01, 0.125, 0.2,
                longContext: (
                    100_000, ClaudeRates(input: 0.5, output: 2.5, cacheRead: 0.05, cacheWrite: 0.625, cacheWrite1h: 1)
                )),
            "claude-haiku-4-5": claude(1, 5, 0.1, 1.25, 2),
            "claude-haiku-3-5": claude(0.8, 4, 0.08, 1, 1.6),
            "claude-haiku-3": claude(0.25, 1.25, 0.03, 0.3, 0.5),
        ]
    }()

    /// Opaque IDs with no parsable version.
    private static let claudeAliases = [
        "model_placeholder_m26": "claude-opus-4-6", "model_placeholder_m35": "claude-sonnet-4-6",
    ]

    private static let families = "fable|mythos|opus|sonnet|haiku"
    // Date stamps and context suffixes such as -1m are excluded from minor-version matches.
    private static let familyFirst = try! NSRegularExpression(
        pattern: "(?:^|[^a-z])(?<family>\(families))-(?<major>\\d{1,2})(?:-(?<minor>\\d{1,2})(?![0-9a-z]))?(?![0-9])")
    // Legacy version-first IDs from historical logs, such as claude-3-5-sonnet-20241022.
    private static let versionFirst = try! NSRegularExpression(
        pattern: "(?:^|[^0-9a-z])(?<major>\\d{1,2})(?:-(?<minor>\\d{1,2}))?-(?<family>\(families))(?![a-z])")

    private static let claudeKeys = Mutex<[String: String?]>([:])

    /// The pricing table key for a Claude model ID, or nil when it is not priced.
    static func normalizeClaudeModel(_ model: String) -> String? {
        if let cached = claudeKeys.withLock({ $0[model] }) { return cached }
        let key = parseClaudeModel(model)
        claudeKeys.withLock { $0[model] = .some(key) }
        return key
    }

    private static func parseClaudeModel(_ model: String) -> String? {
        let lower = model.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return nil }
        if let alias = claudeAliases[lower] { return alias }
        let text = lower.replacingOccurrences(of: ".", with: "-")
        let range = NSRange(text.startIndex..., in: text)
        guard let match = familyFirst.firstMatch(in: text, range: range) ?? versionFirst.firstMatch(in: text, range: range)
        else { return nil }
        func group(_ name: String) -> String? {
            let found = match.range(withName: name)
            guard found.location != NSNotFound, let swiftRange = Range(found, in: text) else { return nil }
            return String(text[swiftRange])
        }
        guard let family = group("family"), let major = group("major") else { return nil }
        let key = group("minor").map { "claude-\(family)-\(major)-\($0)" } ?? "claude-\(family)-\(major)"
        return claudeTable[key] == nil ? nil : key
    }

    static func claudePricing(_ model: String) -> ClaudePricing? {
        normalizeClaudeModel(model).flatMap { claudeTable[$0] }
    }

    // MARK: Codex

    struct CodexRates: Sendable {
        let input: Double
        let cachedInput: Double
        let output: Double

        /// `tokens.input` is new input only; cached input is `tokens.cacheRead`.
        func price(_ tokens: UsageTokens) -> Double {
            (Double(max(tokens.input, 0)) * input + Double(max(tokens.cacheRead, 0)) * cachedInput
                + Double(max(tokens.output, 0)) * output) / 1_000_000
        }
    }

    struct CodexPricing: Sendable {
        let rates: CodexRates
        let longContext: CodexRates?
    }

    /// Input above this many tokens in one request bills at the long-context rates.
    static let codexLongContextThreshold = 272_000

    private static func codex(_ input: Double, _ cached: Double, _ output: Double, long: (Double, Double, Double)? = nil)
        -> CodexPricing
    {
        CodexPricing(
            rates: CodexRates(input: input, cachedInput: cached, output: output),
            longContext: long.map { CodexRates(input: $0.0, cachedInput: $0.1, output: $0.2) })
    }

    static let codexTable: [String: CodexPricing] = [
        "gpt-5": codex(1.25, 0.125, 10),
        "gpt-5.1": codex(1.25, 0.125, 10),
        "gpt-5.1-codex": codex(1.25, 0.125, 10),
        "gpt-5.1-codex-max": codex(1.25, 0.125, 10),
        "gpt-5.2": codex(1.75, 0.175, 14),
        "gpt-5.2-pro": codex(21, 21, 168),
        "gpt-5.2-codex": codex(1.75, 0.175, 14),
        "gpt-5.3": codex(1.75, 0.175, 14),
        "gpt-5.3-codex": codex(1.75, 0.175, 14),
        "gpt-5.3-codex-spark": codex(1.75, 0.175, 14),
        "gpt-5.4-mini": codex(0.75, 0.075, 4.5),
        "gpt-5.4-nano": codex(0.2, 0.02, 1.25),
        "gpt-5.4-pro": codex(30, 30, 180, long: (60, 60, 270)),
        "gpt-5.4": codex(2.5, 0.25, 15, long: (5, 0.5, 22.5)),
        "gpt-5.5-pro": codex(30, 30, 180, long: (60, 60, 270)),
        "gpt-5.5": codex(5, 0.5, 30, long: (10, 1, 45)),
        // Promotional Sol rates are listed through at least 2026-11-21.
        "gpt-5.6-sol": codex(4, 0.4, 20, long: (8, 0.8, 30)),
        "gpt-5.6-terra": codex(2, 0.2, 12, long: (4, 0.4, 18)),
        "gpt-5.6-luna": codex(0.2, 0.02, 1.2, long: (0.4, 0.04, 1.8)),
        "gpt-6-astra": codex(10, 1, 50, long: (20, 2, 75)),
        "gpt-6-sol": codex(2, 0.2, 10, long: (4, 0.4, 15)),
        "gpt-6.1-sol": codex(2, 0.1, 10, long: (4, 0.2, 15)),
        "gpt-6-luna": codex(0.1, 0.01, 0.5, long: (0.2, 0.02, 0.75)),
    ]

    private static let reasoningTiers = ["minimal", "low", "medium", "high", "xhigh", "auto", "none"]
    // Names ending in "-max" are real models; max/ultra are tiers only inside parentheses.
    private static let parenthesizedTiers = reasoningTiers + ["max", "ultra"]

    /// Longest names first, so `gpt-5.1-codex-max` wins over `gpt-5.1-codex` and `gpt-5.1`.
    private static let codexKeysByLength = codexTable.keys.sorted { $0.count > $1.count || ($0.count == $1.count && $0 < $1) }

    /// The pricing table key for a Codex model name, or nil when it is not priced.
    static func normalizeCodexModel(_ model: String) -> String? {
        var name = model.lowercased().trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            let tier = name[name.index(after: open)..<name.index(before: name.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            guard parenthesizedTiers.contains(tier) else { return nil }
            name = name[..<open].trimmingCharacters(in: .whitespaces)
        }
        for _ in 0..<4 {
            guard let tier = reasoningTiers.first(where: { name.hasSuffix("-\($0)") }) else { break }
            name.removeLast(tier.count + 1)
        }
        if name == "gpt-5" || name == "gpt-5-codex" { return "gpt-5" }
        // Exact alias only, so future cheaper 5.6 variants do not inherit Sol rates.
        if name == "gpt-5.6" { return "gpt-5.6-sol" }
        return codexKeysByLength.first { $0 != "gpt-5" && (name == $0 || name.hasPrefix("\($0)-")) }
    }

    static func codexPricing(_ model: String) -> CodexPricing? {
        normalizeCodexModel(model).flatMap { codexTable[$0] }
    }
}

import Foundation

/// Changes applied to a base environment before a process starts: keys to set, then keys to remove.
/// A key present in both is set (an explicit value wins over a removal).
public struct EnvPatch: Sendable, Hashable {
    public var set: [String: String]
    public var unset: Set<String>

    public init(set: [String: String] = [:], unset: Set<String> = []) {
        self.set = set
        self.unset = unset
    }

    public static let empty = EnvPatch()

    public func applied(to base: [String: String]) -> [String: String] {
        var result = base
        for key in unset where set[key] == nil { result.removeValue(forKey: key) }
        for (key, value) in set { result[key] = value }
        return result
    }

    /// `other` wins on conflicts: its sets override, and its removals drop earlier sets of the same key.
    public func merging(_ other: EnvPatch) -> EnvPatch {
        var merged = self
        for key in other.unset {
            merged.set.removeValue(forKey: key)
            merged.unset.insert(key)
        }
        for (key, value) in other.set {
            merged.set[key] = value
            merged.unset.remove(key)
        }
        return merged
    }
}

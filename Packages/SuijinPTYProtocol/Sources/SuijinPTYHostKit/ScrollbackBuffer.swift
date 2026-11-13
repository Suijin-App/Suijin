import Foundation

/// A byte ring buffer that keeps the most recent `capacity` bytes of a terminal stream.
///
/// Every byte ever appended has an absolute stream offset (`0..<totalWritten`); the buffer holds the window
/// `startOffset..<totalWritten`. Offsets let readers resume exactly where they stopped, which is how the host
/// streams live output after a scrollback snapshot without gaps or duplicates.
public struct ScrollbackBuffer: Sendable {
    public static let defaultCapacity = 8 * 1024 * 1024

    public let capacity: Int
    /// Grows up to `capacity`, then becomes a ring whose oldest byte sits at `head`.
    private var storage: [UInt8] = []
    private var head = 0
    public private(set) var totalWritten: UInt64 = 0

    public init(capacity: Int = ScrollbackBuffer.defaultCapacity) {
        precondition(capacity > 0, "ScrollbackBuffer capacity must be positive")
        self.capacity = capacity
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    /// Absolute offset of the oldest byte still held.
    public var startOffset: UInt64 { totalWritten - UInt64(storage.count) }

    public mutating func append(_ data: Data) {
        data.withUnsafeBytes { append($0) }
    }

    public mutating func append(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { append($0) }
    }

    public mutating func append(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        totalWritten += UInt64(bytes.count)

        if bytes.count >= capacity {
            storage = Array(bytes.suffix(capacity))
            head = 0
            return
        }

        var source = bytes[...]
        if storage.count < capacity {
            let taken = min(capacity - storage.count, source.count)
            storage.append(contentsOf: source.prefix(taken))
            source = source.dropFirst(taken)
            if source.isEmpty { return }
        }

        // Full: overwrite the oldest bytes, wrapping at most once because source.count < capacity.
        let capacity = self.capacity
        var position = head
        storage.withUnsafeMutableBytes { destination in
            while !source.isEmpty {
                let run = min(capacity - position, source.count)
                let chunk = UnsafeRawBufferPointer(rebasing: source.prefix(run))
                UnsafeMutableRawBufferPointer(rebasing: destination[position..<(position + run)]).copyMemory(from: chunk)
                position = (position + run) % capacity
                source = source.dropFirst(run)
            }
        }
        head = position
    }

    /// Bytes from absolute `offset` (clamped to `startOffset`) up to `maxLength` bytes.
    public func read(from offset: UInt64, maxLength: Int = .max) -> Data {
        let start = max(offset, startOffset)
        guard start < totalWritten, maxLength > 0 else { return Data() }
        let logical = Int(start - startOffset)
        let length = min(storage.count - logical, maxLength)

        var result = Data(capacity: length)
        storage.withUnsafeBytes { raw in
            // Logical index k lives at (head + k) % capacity; while not full, head is 0 and storage is linear.
            let first = (head + logical) % max(storage.count, 1)
            let firstRun = min(length, storage.count - first)
            result.append(contentsOf: raw[first..<(first + firstRun)])
            if firstRun < length {
                result.append(contentsOf: raw[0..<(length - firstRun)])
            }
        }
        return result
    }

    /// Everything currently held, oldest first.
    public func snapshot() -> Data {
        read(from: startOffset)
    }
}

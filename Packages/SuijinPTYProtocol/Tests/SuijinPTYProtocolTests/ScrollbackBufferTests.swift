import Foundation
import SuijinPTYHostKit
import Testing

@Suite("ScrollbackBuffer")
struct ScrollbackBufferTests {
    @Test func keepsEverythingUnderCapacity() {
        var buffer = ScrollbackBuffer(capacity: 16)
        buffer.append(Array("hello ".utf8))
        buffer.append(Array("world".utf8))
        #expect(buffer.snapshot() == Data("hello world".utf8))
        #expect(buffer.count == 11)
        #expect(buffer.totalWritten == 11)
        #expect(buffer.startOffset == 0)
    }

    @Test func wrapsAndDropsOldestBytes() {
        var buffer = ScrollbackBuffer(capacity: 8)
        buffer.append(Array("abcdef".utf8))
        buffer.append(Array("ghij".utf8))
        #expect(buffer.snapshot() == Data("cdefghij".utf8))
        #expect(buffer.count == 8)
        #expect(buffer.totalWritten == 10)
        #expect(buffer.startOffset == 2)
        buffer.append(Array("klmnopq".utf8)) // wraps across the end of storage
        #expect(buffer.snapshot() == Data("jklmnopq".utf8))
        #expect(buffer.startOffset == 9)
    }

    @Test func chunkLargerThanCapacityKeepsItsTail() {
        var buffer = ScrollbackBuffer(capacity: 4)
        buffer.append(Array("xy".utf8))
        buffer.append(Array("0123456789".utf8))
        #expect(buffer.snapshot() == Data("6789".utf8))
        #expect(buffer.totalWritten == 12)
    }

    @Test func readsByAbsoluteOffset() {
        var buffer = ScrollbackBuffer(capacity: 8)
        buffer.append(Array("0123456789".utf8)) // holds offsets 2..<10
        #expect(buffer.read(from: 0) == Data("23456789".utf8), "offsets before the window are clamped")
        #expect(buffer.read(from: 5) == Data("56789".utf8))
        #expect(buffer.read(from: 5, maxLength: 2) == Data("56".utf8))
        #expect(buffer.read(from: 10).isEmpty)
        #expect(buffer.read(from: 99).isEmpty)
    }

    @Test func matchesReferenceModelUnderRandomAppends() {
        var generator = SplitMix64(seed: 0x5EED)
        for capacity in [1, 7, 64, 1000] {
            var buffer = ScrollbackBuffer(capacity: capacity)
            var reference: [UInt8] = []
            for _ in 0..<500 {
                let length = Int(generator.next() % UInt64(capacity * 2 + 1))
                let chunk = (0..<length).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
                buffer.append(chunk)
                reference.append(contentsOf: chunk)
                let expected = Data(reference.suffix(capacity))
                #expect(buffer.snapshot() == expected)
                let offset = UInt64(generator.next() % UInt64(reference.count + 1))
                let expectedTail = Data(reference[Int(max(offset, buffer.startOffset))...])
                #expect(buffer.read(from: offset) == expectedTail)
            }
            #expect(buffer.totalWritten == UInt64(reference.count))
        }
    }

    @Test func defaultCapacityIsEightMegabytes() {
        #expect(ScrollbackBuffer().capacity == 8 * 1024 * 1024)
    }
}

/// Deterministic generator so the property test is reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

import Foundation
@testable import SevindaUsage

/// Builds synthetic log lines and temporary log folders. Tests never read real logs.
enum Fixture {
    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func claude(
        messageID: String? = "msg_1", requestID: String? = "req_1", uuid: String? = nil, session: String? = "s1",
        timestamp: String = "2026-11-10T12:00:00.000Z", model: String = "claude-opus-4-5-20251101",
        cwd: String? = "/Users/me/Code/alpha", input: Int = 100, output: Int = 50, cacheRead: Int = 1_000,
        cacheWrite: Int = 200, cacheWrite1h: Int? = nil, type: String = "assistant"
    ) -> String {
        var usage: [String: Any] = [
            "input_tokens": input, "output_tokens": output, "cache_read_input_tokens": cacheRead,
            "cache_creation_input_tokens": cacheWrite,
        ]
        if let cacheWrite1h {
            usage["cache_creation"] = [
                "ephemeral_1h_input_tokens": cacheWrite1h, "ephemeral_5m_input_tokens": cacheWrite - cacheWrite1h,
            ]
        }
        var message: [String: Any] = ["model": model, "usage": usage, "role": "assistant", "content": []]
        if let messageID { message["id"] = messageID }
        var record: [String: Any] = ["type": type, "timestamp": timestamp, "message": message]
        if let requestID { record["requestId"] = requestID }
        if let uuid { record["uuid"] = uuid }
        if let session { record["sessionId"] = session }
        if let cwd { record["cwd"] = cwd }
        return json(record)
    }

    static func codexMeta(id: String = "codex-session-1", cwd: String = "/Users/me/Code/beta") -> String {
        json(["type": "session_meta", "timestamp": "2026-11-10T11:00:00.000Z", "payload": ["id": id, "cwd": cwd]])
    }

    static func codexTurn(turnID: String = "turn-1", model: String = "gpt-5.5", cwd: String? = nil) -> String {
        var payload: [String: Any] = ["turn_id": turnID, "model": model]
        if let cwd { payload["cwd"] = cwd }
        return json(["type": "turn_context", "timestamp": "2026-11-10T11:00:01.000Z", "payload": payload])
    }

    static func usage(_ input: Int, cached: Int, output: Int, reasoning: Int = 0) -> [String: Any] {
        [
            "input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
            "reasoning_output_tokens": reasoning, "total_tokens": input + output,
        ]
    }

    static func codexTokens(
        total: [String: Any]?, last: [String: Any]?, timestamp: String = "2026-11-10T12:00:00.000Z"
    ) -> String {
        var info: [String: Any] = [:]
        if let total { info["total_token_usage"] = total }
        if let last { info["last_token_usage"] = last }
        return json([
            "type": "event_msg", "timestamp": timestamp,
            "payload": ["type": "token_count", "info": info],
        ])
    }

    static func codexRateLimitOnly() -> String {
        json(["type": "event_msg", "timestamp": "2026-11-10T12:00:00.000Z", "payload": ["type": "token_count", "info": NSNull()]])
    }

    /// A fresh temporary folder, removed by `cleanup`.
    final class Folder {
        let url: URL

        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mercury-usage-tests-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func file(_ relative: String) -> URL {
            let target = url.appendingPathComponent(relative)
            try! FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            return target
        }

        @discardableResult
        func write(_ relative: String, lines: [String], trailingNewline: Bool = true) -> URL {
            let target = file(relative)
            let text = lines.joined(separator: "\n") + (trailingNewline && !lines.isEmpty ? "\n" : "")
            try! Data(text.utf8).write(to: target)
            return target
        }

        func append(_ relative: String, _ text: String) {
            let handle = try! FileHandle(forWritingTo: url.appendingPathComponent(relative))
            try! handle.seekToEnd()
            try! handle.write(contentsOf: Data(text.utf8))
            try! handle.close()
        }
    }
}

extension UnsafeRawBufferPointer {
    /// Runs `body` with the UTF-8 bytes of `text`.
    static func with<T>(_ text: String, _ body: (UnsafeRawBufferPointer) -> T) -> T {
        var copy = text
        return copy.withUTF8 { body(UnsafeRawBufferPointer($0)) }
    }
}

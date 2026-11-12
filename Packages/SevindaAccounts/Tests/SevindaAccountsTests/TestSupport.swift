import Foundation
import Synchronization
@testable import SevindaAccounts

/// A throwaway folder with a fake user home (`realHome`) and data root. Nothing outside it is ever touched.
final class Sandbox: Sendable {
    let base: URL
    let realHome: URL
    let dataRoot: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("sevinda-accounts-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // Resolve /var -> /private/var once so path comparisons are exact.
        base = URL(fileURLWithPath: try FileOps.realpath(raw.path)!, isDirectory: true)
        realHome = base.appendingPathComponent("home", isDirectory: true)
        dataRoot = base.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    var claudeHome: URL { realHome.appendingPathComponent(".claude", isDirectory: true) }
    var codexHome: URL { realHome.appendingPathComponent(".codex", isDirectory: true) }

    @discardableResult
    func write(_ text: String, to url: URL, mode: Int = 0o644) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try write(String(decoding: data, as: UTF8.self), to: url)
    }

    func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A shell script used as a fake CLI.
    func script(_ name: String, _ body: String) throws -> URL {
        try write("#!/bin/sh\n\(body)\n", to: base.appendingPathComponent("bin/\(name)"), mode: 0o755)
    }
}

func readJSON(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
}

func readText(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

func posixMode(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

func symlinkTarget(_ url: URL) -> String? {
    try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
}

/// Every file below `root` with its bytes, to prove a tree was not modified.
func treeSnapshot(_ root: URL) -> [String: Data] {
    var result: [String: Data] = [:]
    guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return result }
    while let relative = enumerator.nextObject() as? String {
        let path = root.appendingPathComponent(relative).path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            result[relative] = isDirectory.boolValue ? Data("<dir>".utf8) : (FileManager.default.contents(atPath: path) ?? Data())
        } else {
            result[relative] = Data("<dangling>".utf8)
        }
    }
    return result
}

/// Records commands and answers them from a closure; never runs anything.
final class FakeCommandRunner: CommandRunning {
    struct Call: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]?
    }

    private let calls = Mutex<[Call]>([])
    private let respond: @Sendable (Call) -> CommandResult

    init(_ respond: @escaping @Sendable (Call) -> CommandResult = { _ in CommandResult(exitCode: 44, stdout: Data(), stderr: Data()) }) {
        self.respond = respond
    }

    var recorded: [Call] { calls.withLock { $0 } }

    func run(
        _ executable: URL, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult {
        let call = Call(executable: executable.path, arguments: arguments, environment: environment)
        calls.withLock { $0.append(call) }
        return respond(call)
    }
}

/// Answers HTTP requests with a fixed response and records them.
final class FakeTransport: HTTPTransport {
    private let requests = Mutex<[URLRequest]>([])
    let status: Int
    let body: Data

    init(status: Int = 200, json: String) {
        self.status = status
        body = Data(json.utf8)
    }

    var recorded: [URLRequest] { requests.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// Collects a login session's output lines until the stream ends.
func collect(_ session: LoginSession) async -> [String] {
    var lines: [String] = []
    for await line in session.output { lines.append(line) }
    return lines
}

func base64URL(_ object: [String: Any]) throws -> String {
    try JSONSerialization.data(withJSONObject: object).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

import Foundation
import Testing
@testable import SevindaAccounts

@Suite struct CodexNotifyConfigTests {
    @Test func hookAloneWithoutAUserNotify() {
        #expect(CodexNotifyConfig.launchArguments(cli: "/Apps/Sevinda.app/Contents/Helpers/sevinda", config: nil)
                == ["-c", #"notify=["/Apps/Sevinda.app/Contents/Helpers/sevinda","hook","codex-notify"]"#])
        #expect(CodexNotifyConfig.launchArguments(cli: "/m", config: "model = \"x\"\n[tui]\nnotify = [\"no\"]\n")
                == ["-c", #"notify=["/m","hook","codex-notify"]"#], "a notify inside a table is not the top-level one")
    }

    @Test func chainsTheUsersOwnNotify() {
        let config = """
        model = "gpt"
        notify = ["/Users/me/My App.app/Contents/MacOS/client", "turn-ended"] # theirs

        [projects."/x"]
        trust_level = "trusted"
        """
        #expect(CodexNotifyConfig.launchArguments(cli: "/m", config: config)
                == ["-c", #"notify=["/m","hook","codex-notify","--","/Users/me/My App.app/Contents/MacOS/client","turn-ended"]"#])
        let multiline = "notify = [\n  'say',  # literal\n  \"done \\\"now\\\"\",\n]\n"
        #expect(CodexNotifyConfig.notifyCommand(in: multiline) == ["say", "done \"now\""])
    }

    @Test func neverChainsSevindaTwice() {
        let config = #"notify = ["/old/sevinda", "hook", "codex-notify", "--", "/bin/echo"]"#
        #expect(CodexNotifyConfig.launchArguments(cli: "/m", config: config) == ["-c", #"notify=["/m","hook","codex-notify"]"#])
    }

    @Test func rejectsWhatIsNotAStringArray() {
        #expect(CodexNotifyConfig.notifyCommand(in: "notify = \"just a string\"") == nil)
        #expect(CodexNotifyConfig.notifyCommand(in: "notify = [1, 2]") == nil)
        #expect(CodexNotifyConfig.notifyCommand(in: "notify = [\"unterminated") == nil)
    }

    @Test func escapesTOMLStrings() {
        #expect(CodexNotifyConfig.tomlString("a\"b\\c\nd") == #""a\"b\\c\nd""#)
    }

    @Test func readsTheConfigCodexWillUse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notify-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try "notify = [\"home\"]".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "notify = [\"real\"]".write(to: real.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        #expect(CodexNotifyConfig.effectiveConfig(home: home, environment: [:], realHome: real) == "notify = [\"home\"]")
        #expect(CodexNotifyConfig.effectiveConfig(home: nil, environment: [:], realHome: real) == "notify = [\"real\"]")
        #expect(CodexNotifyConfig.effectiveConfig(home: nil, environment: ["CODEX_HOME": home.path], realHome: real) == "notify = [\"home\"]")
    }
}

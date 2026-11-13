import Foundation
import Testing
@testable import SuijinTerminal

@Suite("Shell integration")
struct ShellIntegrationTests {
    @Test("install writes every file and leaves up-to-date files alone")
    func installWritesFiles() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        #expect(fixture.integration.lastPathComponent == ShellIntegration.directoryName)
        for file in ShellIntegration.files {
            let url = fixture.integration.appending(path: file.destination)
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(file.destination)")
        }
        let zshrc = fixture.integration.appending(path: "zsh/.zshrc")
        let before = try FileManager.default.attributesOfItem(atPath: zshrc.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        try ShellIntegration.install(in: fixture.dataRoot)
        let after = try FileManager.default.attributesOfItem(atPath: zshrc.path)[.modificationDate] as? Date
        #expect(before == after)

        try Data("stale".utf8).write(to: zshrc)
        try ShellIntegration.install(in: fixture.dataRoot)
        #expect(try String(contentsOf: zshrc, encoding: .utf8).contains("Suijin shell integration"))
    }

    @Test("interactiveShell points zsh at the wrapper and remembers the user's ZDOTDIR")
    func zshLaunch() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let launch = ShellLaunch.interactiveShell("/bin/zsh", cwd: fixture.home,
                                                  environment: fixture.environment(["ZDOTDIR": "/custom/zdot"]))
        #expect(launch.executable == "/bin/zsh")
        #expect(launch.arguments == ["-l"])
        #expect(launch.cwd == fixture.home.path)
        #expect(launch.environment["ZDOTDIR"] == ShellIntegration.zshDirectory(in: fixture.integration).path)
        #expect(launch.environment["SUIJIN_USER_ZDOTDIR"] == "/custom/zdot")
        #expect(launch.environment["SHELL"] == "/bin/zsh")

        let bash = ShellLaunch.interactiveShell("/bin/bash", cwd: fixture.home, environment: fixture.environment())
        #expect(bash.arguments == ["--rcfile", ShellIntegration.bashRCFile(in: fixture.integration).path, "-i"])
        #expect(bash.environment["ZDOTDIR"] == nil)

        let fish = ShellLaunch.interactiveShell("/opt/homebrew/bin/fish", cwd: fixture.home, environment: fixture.environment())
        #expect(fish.arguments == ["-l"])
    }

    // MARK: zsh

    @Test("zsh sources the user's files in order, then defines claude, then restores ZDOTDIR")
    func zshStartupOrder() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.write("print -r -- step=zshenv\n", to: ".zshenv")
        try fixture.write("print -r -- step=zprofile\n", to: ".zprofile")
        try fixture.write("""
            print -r -- step=zshrc
            \(fixture.pathLine)
            if typeset -f claude >/dev/null; then print -r -- early=defined; else print -r -- early=none; fi
            typeset -A user_map=(a 1)
            """, to: ".zshrc")
        try fixture.write("print -r -- step=zlogin\n", to: ".zlogin")

        let output = try fixture.run(shell: "/bin/zsh", script: """
            whence -w claude; whence -w codex
            print -r -- "zdotdir=${ZDOTDIR-<unset>}"
            print -r -- "map=${user_map[a]}"
            print -r -- "histfile=$HISTFILE"
            print -r -- "leftover=${__suijin_zdotdir-<none>}${SUIJIN_USER_ZDOTDIR-<none>}"
            """)
        let steps = output.split(separator: "\n").filter { $0.hasPrefix("step=") }
        #expect(steps == ["step=zshenv", "step=zprofile", "step=zshrc", "step=zlogin"])
        #expect(output.value(of: "early") == "none")
        #expect(output.contains("claude: function"))
        #expect(output.contains("codex: function"))
        #expect(output.value(of: "zdotdir") == "<unset>")
        // Top-level sourcing: a `typeset` in the user's .zshrc stays global.
        #expect(output.value(of: "map") == "1")
        #expect(output.value(of: "histfile") == fixture.home.path + "/.zsh_history")
        #expect(output.value(of: "leftover") == "<none><none>")
    }

    @Test("zsh and bash report the working directory at each prompt (OSC 7)", arguments: ["/bin/zsh", "/bin/bash"])
    func reportsWorkingDirectory(shell: String) throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let folder = fixture.home.appending(path: "a b%c", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hook = shell.hasSuffix("zsh") ? #"print -r -- "hooks=${precmd_functions[*]}""# : #"echo "hooks=$PROMPT_COMMAND""#
        let output = try fixture.run(shell: shell, script: "\(hook); cd 'a b%c'; __suijin_report_cwd")
        #expect(output.value(of: "hooks")?.contains("__suijin_report_cwd") == true)
        let report = try #require(output.range(of: "\u{1b}]7;").map { String(output[$0.upperBound...]) })
        let sequence = try #require(report.split(separator: "\u{07}").first.map(String.init))
        let reported = try #require(SuijinTerminalView.directory(fromOSC7: sequence))
        #expect(URL(fileURLWithPath: reported).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
    }

    @Test("an OSC 7 report reads as a path")
    func osc7Paths() {
        #expect(SuijinTerminalView.directory(fromOSC7: "file://mac.local/Users/me/a%20b") == "/Users/me/a b")
        #expect(SuijinTerminalView.directory(fromOSC7: "file:///tmp/x y") == "/tmp/x y")
        #expect(SuijinTerminalView.directory(fromOSC7: "/tmp") == "/tmp")
        #expect(SuijinTerminalView.directory(fromOSC7: "file://host") == nil)
        #expect(SuijinTerminalView.directory(fromOSC7: nil) == nil)
    }

    @Test("zsh reads startup files from the user's own ZDOTDIR and puts it back")
    func zshUserZDOTDIR() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let userDir = fixture.base.appending(path: "config zsh", directoryHint: .isDirectory)
        try fixture.write("print -r -- wrong-zshrc\n", to: ".zshrc")
        try fixture.write("print -r -- step=user-zshrc\n" + fixture.pathLine, to: ".zshrc", in: userDir)
        let output = try fixture.run(shell: "/bin/zsh", script: #"print -r -- "zdotdir=$ZDOTDIR"; whence -w claude"#,
                                     environment: ["ZDOTDIR": userDir.path])
        #expect(output.contains("step=user-zshrc"))
        #expect(!output.contains("wrong-zshrc"))
        #expect(output.value(of: "zdotdir") == userDir.path)
        #expect(output.contains("claude: function"))
    }

    @Test("a ZDOTDIR moved by the user's .zshenv is followed")
    func zshZDOTDIRMovedByZshenv() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let userDir = fixture.home.appending(path: ".config/zsh", directoryHint: .isDirectory)
        try fixture.write("export ZDOTDIR=\"$HOME/.config/zsh\"\n", to: ".zshenv")
        try fixture.write("print -r -- step=moved-zshrc\n", to: ".zshrc", in: userDir)
        let output = try fixture.run(shell: "/bin/zsh", script: #"print -r -- "zdotdir=$ZDOTDIR""#)
        #expect(output.contains("step=moved-zshrc"))
        #expect(output.value(of: "zdotdir") == userDir.path)
    }

    @Test("zsh claude follows the pointer file and drops API-key variables")
    func zshClaudePointer() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.pathLine, to: ".zshrc")
        let account = fixture.dataRoot.appending(path: "claude-profiles/A/home").path
        try fixture.selectAccount(account + "\n")
        let secrets = ["ANTHROPIC_API_KEY": "test-key", "CLAUDE_CODE_OAUTH_TOKEN": "test-token"]

        let routed = try fixture.run(shell: "/bin/zsh", script: "claude --version", environment: secrets)
        #expect(routed.value(of: "claude-config") == account)
        #expect(routed.value(of: "claude-key") == "<unset>")
        #expect(routed.value(of: "claude-token") == "<unset>")
        #expect(routed.value(of: "claude-args") == "--version")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: account, isDirectory: &isDirectory) && isDirectory.boolValue)

        // Switching accounts applies to the next run in the same shell.
        let other = fixture.dataRoot.appending(path: "claude-profiles/B/home").path
        let switched = try fixture.run(shell: "/bin/zsh", script: """
            claude; printf '%s' '\(other)' > "$SUIJIN_DATA_ROOT/claude-profiles/selected-host"; claude
            """)
        let configs = switched.split(separator: "\n").filter { $0.hasPrefix("claude-config=") }
        #expect(configs == ["claude-config=\(account)", "claude-config=\(other)"])

        try fixture.selectAccount(nil)
        let defaultLogin = try fixture.run(shell: "/bin/zsh", script: "claude", environment: secrets)
        #expect(defaultLogin.value(of: "claude-config") == "<unset>")
        #expect(defaultLogin.value(of: "claude-key") == "test-key")
    }

    @Test("zsh claude honours a CLAUDE_CONFIG_DIR the user set")
    func zshClaudeUserConfigDir() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.pathLine, to: ".zshrc")
        try fixture.selectAccount("/accounts/selected")
        let inherited = try fixture.run(shell: "/bin/zsh", script: "claude", environment: ["CLAUDE_CONFIG_DIR": "/mine"])
        #expect(inherited.value(of: "claude-config") == "/mine")
        let typed = try fixture.run(shell: "/bin/zsh", script: "CLAUDE_CONFIG_DIR=/typed claude")
        #expect(typed.value(of: "claude-config") == "/typed")
    }

    @Test("zsh keeps a claude function the user defined")
    func zshUserFunctionWins() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.pathLine + "claude() { print -r -- user-claude; }\n", to: ".zshrc")
        try fixture.selectAccount("/accounts/selected")
        let output = try fixture.run(shell: "/bin/zsh", script: "claude")
        #expect(output.contains("user-claude"))
        #expect(output.value(of: "claude-config") == nil)
    }

    @Test("zsh refuses a relative account pointer")
    func zshRelativePointer() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.pathLine, to: ".zshrc")
        try fixture.selectAccount("relative/path")
        let output = try fixture.run(shell: "/bin/zsh", script: "claude; print -r -- status=$?")
        #expect(output.value(of: "claude-config") == nil)
        #expect(output.value(of: "status") == "1")
    }

    @Test("zsh codex follows its own pointer and drops OPENAI_API_KEY")
    func zshCodexPointer() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.pathLine, to: ".zshrc")
        let home = fixture.dataRoot.appending(path: "codex-homes/A/home").path
        try fixture.selectAccount(home, provider: "codex-homes")
        let routed = try fixture.run(shell: "/bin/zsh", script: "codex", environment: ["OPENAI_API_KEY": "test-key"])
        #expect(routed.value(of: "codex-home") == home)
        #expect(routed.value(of: "codex-key") == "<unset>")
        let own = try fixture.run(shell: "/bin/zsh", script: "codex", environment: ["CODEX_HOME": "/mine"])
        #expect(own.value(of: "codex-home") == "/mine")
    }

    // MARK: bash

    @Test("bash reads the login files, then defines claude and codex")
    func bashStartup() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.write("echo step=bash_profile\n" + fixture.pathLine
            + "if type claude 2>/dev/null | grep -q function; then echo early=defined; else echo early=none; fi\n",
            to: ".bash_profile")
        try fixture.write("echo step=bashrc\n", to: ".bashrc")
        let output = try fixture.run(shell: "/bin/bash", script: "type -t claude; type -t codex")
        #expect(output.contains("step=bash_profile"))
        // A login shell reads .bashrc only when .bash_profile sources it.
        #expect(!output.contains("step=bashrc"))
        #expect(output.value(of: "early") == "none")
        #expect(output.split(separator: "\n").filter { $0 == "function" }.count == 2)
    }

    @Test("bash falls back to .bashrc when no login file exists")
    func bashBashrcFallback() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.write("echo step=bashrc\n" + fixture.pathLine, to: ".bashrc")
        let output = try fixture.run(shell: "/bin/bash", script: "type -t claude")
        #expect(output.contains("step=bashrc"))
        #expect(output.contains("function"))
    }

    @Test("bash claude follows the pointer and honours CLAUDE_CONFIG_DIR and a user function")
    func bashClaude() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.pathLine, to: ".bash_profile")
        let account = fixture.dataRoot.appending(path: "claude-profiles/A/home").path
        try fixture.selectAccount(account)

        let routed = try fixture.run(shell: "/bin/bash", script: "claude -p hi", environment: ["ANTHROPIC_API_KEY": "test-key"])
        #expect(routed.value(of: "claude-config") == account)
        #expect(routed.value(of: "claude-key") == "<unset>")
        #expect(routed.value(of: "claude-args") == "-p hi")

        let own = try fixture.run(shell: "/bin/bash", script: "claude", environment: ["CLAUDE_CONFIG_DIR": "/mine"])
        #expect(own.value(of: "claude-config") == "/mine")

        try fixture.write(fixture.pathLine + "claude() { echo user-claude; }\n", to: ".bash_profile")
        let userFunction = try fixture.run(shell: "/bin/bash", script: "claude")
        #expect(userFunction.contains("user-claude"))
        #expect(userFunction.value(of: "claude-config") == nil)
    }

    @Test("bash codex follows its pointer")
    func bashCodex() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.pathLine, to: ".bash_profile")
        let home = fixture.dataRoot.appending(path: "codex-homes/A/home").path
        try fixture.selectAccount(home, provider: "codex-homes")
        let routed = try fixture.run(shell: "/bin/bash", script: "codex", environment: ["OPENAI_API_KEY": "test-key"])
        #expect(routed.value(of: "codex-home") == home)
        #expect(routed.value(of: "codex-key") == "<unset>")
    }
}

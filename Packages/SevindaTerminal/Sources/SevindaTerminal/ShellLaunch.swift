import Darwin
import Foundation

/// How Sevinda starts shells and commands so they behave as in the user's own terminal app.
public enum ShellLaunch {
    /// The fallback when the account's shell is missing or not executable.
    public static let fallbackShell = "/bin/zsh"

    /// Environment variables set by the GUI launch context (launchd, Xcode, a parent Claude Code session) that must
    /// not leak into the user's terminals.
    static let strippedPrefixes = ["DYLD_", "__XPC_", "XPC_", "__CF", "OS_ACTIVITY_", "MallocNano", "NSZombie", "CLAUDE_CODE_"]
    static let strippedKeys: Set<String> = ["CLAUDECODE", "NSUnbufferedIO", "TERM_SESSION_ID", "ITERM_SESSION_ID",
                                            "TERM_PROGRAM_VERSION", "SHLVL", "OLDPWD", "PWD", "_", "SEVINDA_USER_ZDOTDIR"]

    /// The account's login shell (`pw_shell`), falling back to `/bin/zsh`.
    public static func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return fallbackShell
    }

    /// The user's interactive login shell in `cwd`, with Sevinda's shell integration (zsh through a `ZDOTDIR` wrapper,
    /// bash through `--rcfile`). Other shells, fish included, start as a plain login shell.
    ///
    /// `environment` is laid over `baseEnvironment()`. Its `SEVINDA_DATA_ROOT` decides where the integration files
    /// live (`<root>/shell-integration`) and which account pointers the functions read. When the files cannot be
    /// written the shell still starts, without the integration.
    public static func interactiveShell(cwd: URL, environment: [String: String]) -> TerminalLaunch {
        interactiveShell(userShell(), cwd: cwd, environment: environment)
    }

    static func interactiveShell(_ shell: String, cwd: URL, environment: [String: String]) -> TerminalLaunch {
        var env = baseEnvironment().merging(environment) { _, new in new }
        env["SHELL"] = shell
        var arguments = ["-l"]

        let integration = env["SEVINDA_DATA_ROOT"].flatMap { try? ShellIntegration.install(in: URL(fileURLWithPath: $0)) }
        if let integration {
            switch shellName(shell) {
            case "zsh":
                if let userZDOTDIR = env["ZDOTDIR"] { env["SEVINDA_USER_ZDOTDIR"] = userZDOTDIR }
                env["ZDOTDIR"] = ShellIntegration.zshDirectory(in: integration).path
            case "bash":
                arguments = ["--rcfile", ShellIntegration.bashRCFile(in: integration).path, "-i"]
            default:
                break
            }
        }
        return TerminalLaunch(executable: shell, arguments: arguments, environment: env, cwd: cwd.path,
                              metadata: ["kind": "shell"])
    }

    /// Runs `executable` with `args` through the user's interactive login shell
    /// (`$SHELL -l -i -c 'exec "$0" "$@"'`), so `PATH` and the rest of the environment match the user's terminal,
    /// including what `.zshrc` / `.bashrc` set (nvm, volta, `~/.local/bin`): an npm-installed agent's
    /// `#!/usr/bin/env node` finds node. `exec` makes the program the PTY's session process, and anything in
    /// `executable`/`args` (such as `/usr/bin/env -u KEY NAME=value agent …`) runs after the profile, so an environment
    /// patch given that way wins over it.
    ///
    /// bash reads the same files as Sevinda's interactive bash (`--rcfile`, see `ShellIntegration`), or plain `-l -i`
    /// when those cannot be written. fish reads its config in every mode and keeps `-l -c`. Shells that cannot take
    /// this form (csh, tcsh, nu, …) are replaced by `/bin/zsh`.
    ///
    /// `interactive: false` uses a plain login shell (`-l -c`): the rc files and whatever they print (fastfetch,
    /// motd) stay out of the program's terminal. Callers that pass `PATH` themselves (the app resolves it from an
    /// interactive shell once) use it so an agent's screen starts with the agent.
    public static func command(_ executable: String, _ args: [String], cwd: URL, environment: [String: String],
                               interactive: Bool = true) -> TerminalLaunch {
        command(executable, args, shell: userShell(), cwd: cwd,
                environment: baseEnvironment().merging(environment) { _, new in new }, interactive: interactive)
    }

    /// `environment` is complete (not laid over `baseEnvironment()`).
    static func command(_ executable: String, _ args: [String], shell userShell: String, cwd: URL,
                        environment: [String: String], interactive: Bool = true) -> TerminalLaunch {
        let execScript = #"exec "$0" "$@""#
        var shell = userShell
        var env = environment
        env["SHELL"] = userShell
        let arguments: [String]
        switch shellName(userShell) {
        case _ where !interactive:
            if !["zsh", "bash", "sh", "dash", "ksh", "mksh", "yash"].contains(shellName(userShell)) { shell = fallbackShell }
            arguments = ["-l", "-c", execScript, executable] + args
        case "fish":
            // fish passes the arguments after -c's command as $argv.
            arguments = ["-l", "-c", "exec $argv", executable] + args
        case "bash":
            let integration = env["SEVINDA_DATA_ROOT"].flatMap { try? ShellIntegration.install(in: URL(fileURLWithPath: $0)) }
            if let integration {
                arguments = ["--rcfile", ShellIntegration.bashRCFile(in: integration).path, "-i", "-c", execScript, executable] + args
            } else {
                arguments = ["-l", "-i", "-c", execScript, executable] + args
            }
        case "zsh":
            arguments = ["-l", "-i", "-c", execScript, executable] + args
        case "sh", "dash", "ksh", "mksh", "yash":
            arguments = ["-l", "-c", execScript, executable] + args
        default:
            shell = fallbackShell
            arguments = ["-l", "-i", "-c", execScript, executable] + args
        }
        return TerminalLaunch(executable: shell, arguments: arguments, environment: env, cwd: cwd.path,
                              metadata: ["kind": "command"])
    }

    /// The app's environment without launch-context variables, plus what a terminal sets: `TERM=xterm-256color`,
    /// `COLORTERM=truecolor`, `TERM_PROGRAM=Sevinda`, a UTF-8 `LANG`, `SEVINDA_TERMINAL=1` and `SEVINDA_DATA_ROOT`
    /// (inherited when set, else `~/Library/Application Support/Sevinda`).
    public static func baseEnvironment() -> [String: String] {
        baseEnvironment(from: ProcessInfo.processInfo.environment)
    }

    static func baseEnvironment(from inherited: [String: String]) -> [String: String] {
        var env = inherited.filter { key, _ in
            !strippedKeys.contains(key) && !strippedPrefixes.contains { key.hasPrefix($0) }
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Sevinda"
        env["SEVINDA_TERMINAL"] = "1"
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["LOGNAME"] == nil { env["LOGNAME"] = env["USER"] }
        if !isUTF8(env["LC_ALL"] ?? env["LC_CTYPE"] ?? env["LANG"]) {
            env["LANG"] = utf8Locale()
            if let ctype = env["LC_CTYPE"], !isUTF8(ctype) { env.removeValue(forKey: "LC_CTYPE") }
        }
        if env["SEVINDA_DATA_ROOT"] == nil {
            env["SEVINDA_DATA_ROOT"] = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Sevinda", directoryHint: .isDirectory).path
        }
        return env
    }

    static func shellName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func isUTF8(_ locale: String?) -> Bool {
        guard let locale = locale?.lowercased() else { return false }
        return locale.contains("utf-8") || locale.contains("utf8")
    }

    /// `<language>_<region>.UTF-8` for the user's locale when the system has it (Vietnamese → `vi_VN.UTF-8`),
    /// else `en_US.UTF-8`, so typed and printed non-ASCII text is not mangled.
    static func utf8Locale(_ locale: Locale = .current) -> String {
        if let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier {
            let candidate = "\(language)_\(region).UTF-8"
            if FileManager.default.fileExists(atPath: "/usr/share/locale/\(candidate)") { return candidate }
        }
        return "en_US.UTF-8"
    }
}

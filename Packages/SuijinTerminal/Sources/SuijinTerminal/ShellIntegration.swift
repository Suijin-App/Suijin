import Foundation

/// Writes the startup files that let Suijin add its `claude` and `codex` functions to the user's own shell setup.
///
/// Layout under `<root>/shell-integration`:
/// - `zsh/.zshenv`, `.zprofile`, `.zshrc`, `.zlogin`: the `ZDOTDIR` wrappers. Each sources the user's file of the same
///   name from their real `ZDOTDIR` (`SUIJIN_USER_ZDOTDIR`, else `$HOME`); `.zshrc` then sources Suijin's
///   functions; the last file read puts the user's `ZDOTDIR` back.
/// - `suijin.bashrc`: the `--rcfile` for bash, reading what a login shell reads, then Suijin's functions.
/// - `claude-shell-function.{zsh,bash}`, `codex-shell-function.{zsh,bash}`: the account-routing functions, which read
///   `$SUIJIN_DATA_ROOT/claude-profiles/selected-host` and `$SUIJIN_DATA_ROOT/codex-homes/selected-host`.
public enum ShellIntegration {
    /// Name of the directory created under the root passed to `install(in:)`.
    public static let directoryName = "shell-integration"

    public enum InstallError: Error, LocalizedError, Equatable {
        case missingResource(String)

        public var errorDescription: String? {
            switch self {
            case .missingResource(let name): "The shell integration resource \(name) is missing from the app."
            }
        }
    }

    /// Bundled resource (inside `Resources/`) → path relative to the integration directory.
    static let files: [(resource: String, destination: String)] = [
        ("zsh/zshenv.zsh", "zsh/.zshenv"),
        ("zsh/zprofile.zsh", "zsh/.zprofile"),
        ("zsh/zshrc.zsh", "zsh/.zshrc"),
        ("zsh/zlogin.zsh", "zsh/.zlogin"),
        ("suijin.bashrc", "suijin.bashrc"),
        ("claude-shell-function.zsh", "claude-shell-function.zsh"),
        ("claude-shell-function.bash", "claude-shell-function.bash"),
        ("codex-shell-function.zsh", "codex-shell-function.zsh"),
        ("codex-shell-function.bash", "codex-shell-function.bash"),
    ]

    /// Installs (or refreshes) the files under `<root>/shell-integration` and returns that directory. Files already
    /// up to date are left alone, so running shells reading them never see a half-written file.
    @discardableResult
    public static func install(in root: URL) throws -> URL {
        let directory = root.appending(path: directoryName, directoryHint: .isDirectory)
        let fileManager = FileManager.default
        let resources = try resourcesDirectory()
        for file in files {
            let source = resources.appending(path: file.resource)
            guard let contents = fileManager.contents(atPath: source.path) else {
                throw InstallError.missingResource(file.resource)
            }
            let destination = directory.appending(path: file.destination)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.contents(atPath: destination.path) == contents { continue }
            try contents.write(to: destination, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        }
        return directory
    }

    /// The `ZDOTDIR` to start zsh with.
    public static func zshDirectory(in integrationDirectory: URL) -> URL {
        integrationDirectory.appending(path: "zsh", directoryHint: .isDirectory)
    }

    /// The `--rcfile` to start bash with.
    public static func bashRCFile(in integrationDirectory: URL) -> URL {
        integrationDirectory.appending(path: "suijin.bashrc")
    }

    private static func resourcesDirectory() throws -> URL {
        guard let url = Bundle.module.resourceURL?.appending(path: "Resources", directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: url.path) else {
            throw InstallError.missingResource("Resources")
        }
        return url
    }
}

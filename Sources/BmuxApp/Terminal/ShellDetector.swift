import Foundation

/// Shell detection: respect the user's configured environment.
/// Never hardcode /bin/zsh.
enum ShellDetector {
    static var loginShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        // getpwuid fallback via /etc/passwd lookup is overkill for Phase 1;
        // /bin/zsh is the macOS default only as a last resort.
        return "/bin/zsh"
    }

    static var loginShellArguments: [String] {
        // Login shell so profile/rc files load (Homebrew paths, etc.).
        ["-l"]
    }
}

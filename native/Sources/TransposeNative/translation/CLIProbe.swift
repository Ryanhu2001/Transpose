import Foundation

/// A path scan only: launching the CLI and checking its account are separate actions.
enum CLIProbe {
    static var searchDirectories: [String] {
        directories(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    }

    static func discover() -> [DetectedCLI] {
        discover(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    }

    static func discover(environment: [String: String], home: String) -> [DetectedCLI] {
        let roots = directories(environment: environment, home: home)
        return [TranslationProvider.codex, .dsh, .claude, .kimi].compactMap { provider in
            guard let name = provider.cliName else { return nil }
            for root in roots {
                let candidate = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(name).path
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                   !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: candidate) {
                    return DetectedCLI(provider: provider, path: candidate)
                }
            }
            return nil
        }
    }

    private static func directories(environment: [String: String], home: String) -> [String] {
        let inherited = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        let defaults = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            home + "/.local/bin", home + "/.kimi-code/bin", home + "/.cargo/bin",
            home + "/.bun/bin", home + "/.npm-global/bin", home + "/.volta/bin"
        ]
        var seen = Set<String>()
        // Ignore relative PATH entries: GUI requests must never discover a project-local executable.
        return (inherited + defaults).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }
}

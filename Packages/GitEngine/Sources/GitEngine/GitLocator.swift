import Foundation

/// Finds the `git` executable to run.
public enum GitLocator {
    /// Places checked, in order, when no explicit path is configured. Homebrew's git comes first because
    /// people who install it usually want it; `/usr/bin/git` is Apple's shim for the Command Line Tools.
    public static let defaultCandidates: [String] = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/usr/bin/git",
    ]

    /// Returns the first executable git found.
    /// - Parameters:
    ///   - preferredPath: a path the user chose in settings; used if it is executable.
    ///   - environment: checked for `STRONGHOLD_GIT`, an override for development and tests.
    ///   - candidates: fallback locations.
    public static func locate(
        preferredPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidates: [String] = defaultCandidates,
        fileManager: FileManager = .default
    ) -> URL? {
        let ordered = [preferredPath, environment["STRONGHOLD_GIT"]].compactMap { $0 } + candidates
        for path in ordered where !path.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

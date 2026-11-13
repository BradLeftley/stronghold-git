import Foundation

/// Errors thrown by the Git engine.
public enum GitError: Error, Equatable, Sendable {
    /// No usable `git` executable was found.
    case gitNotFound
    /// The `git` executable could not be launched.
    case launchFailed(String)
    /// `git` ran but exited with a non-zero status.
    case commandFailed(arguments: [String], exitCode: Int32, stderr: String)
    /// The directory is not inside a Git working tree.
    case notARepository(URL)
    /// `git` produced output the engine could not understand.
    case unexpectedOutput(String)
    /// The installed git is older than the engine supports.
    case unsupportedVersion(GitVersion)
}

extension GitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .gitNotFound:
            return "Git could not be found. Install the Xcode Command Line Tools or Git from git-scm.com."
        case .launchFailed(let reason):
            return "Git could not be started: \(reason)"
        case .commandFailed(let arguments, let exitCode, let stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = (["git"] + arguments.prefix(2)).joined(separator: " ")
            return message.isEmpty ? "\(command) failed with exit code \(exitCode)." : message
        case .notARepository(let url):
            return "\(url.path) is not a Git repository."
        case .unexpectedOutput(let detail):
            return "Git returned output Stronghold could not read: \(detail)"
        case .unsupportedVersion(let version):
            return "Git \(version) is too old. Stronghold needs Git \(GitVersion.minimumSupported) or later."
        }
    }
}

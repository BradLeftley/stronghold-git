import Foundation

/// A parsed `git --version` result, for example `git version 2.54.0 (Apple Git-157)`.
public struct GitVersion: Comparable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Anything after the numeric version, such as `(Apple Git-157)` or `.windows.1`.
    public var suffix: String

    /// The oldest git the engine is tested against. 2.35 brings `--end-of-options` for every command we use
    /// and stable porcelain v2 output.
    public static let minimumSupported = GitVersion(major: 2, minor: 35, patch: 0)

    public init(major: Int, minor: Int, patch: Int, suffix: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.suffix = suffix
    }

    /// Parses the output of `git --version`. Returns nil if it isn't recognisable.
    public init?(parsing output: String) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("git version ") else { return nil }
        let rest = trimmed.dropFirst("git version ".count)
        let versionToken = rest.prefix { !$0.isWhitespace }
        let suffixText = rest.dropFirst(versionToken.count).trimmingCharacters(in: .whitespaces)
        let parts = versionToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        var patch = 0
        var extra: [Substring] = []
        if parts.count >= 3 {
            if let value = Int(parts[2]) {
                patch = value
                extra = Array(parts.dropFirst(3))
            } else {
                extra = Array(parts.dropFirst(2))
            }
        }
        let extraText = extra.isEmpty ? "" : "." + extra.joined(separator: ".")
        self.init(major: major, minor: minor, patch: patch,
                  suffix: [extraText, suffixText].filter { !$0.isEmpty }.joined(separator: " "))
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public static func == (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
    }
}

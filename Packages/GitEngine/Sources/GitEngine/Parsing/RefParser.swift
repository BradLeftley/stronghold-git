import Foundation

/// Builds the `git for-each-ref` format and parses it. Ref names can't contain NUL or newline, so
/// records are newline-separated and fields NUL-separated.
public enum RefParser {
    static let placeholders = [
        "%(refname)", "%(objectname)", "%(*objectname)", "%(upstream)",
        "%(upstream:track,nobracket)", "%(HEAD)", "%(symref)",
    ]

    public static let format = placeholders.joined(separator: "%00")

    public static func parse(_ data: Data) throws -> [Ref] {
        let text = String(decoding: data, as: UTF8.self)
        return try text.split(separator: "\n").map { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count == placeholders.count, !f[0].isEmpty else {
                throw GitError.unexpectedOutput("ref line \"\(line.prefix(120))\"")
            }
            let name = f[0]
            let kind: Ref.Kind
            if name.hasPrefix("refs/heads/") {
                kind = .localBranch
            } else if name.hasPrefix("refs/remotes/") {
                let remote = name.dropFirst("refs/remotes/".count).prefix { $0 != "/" }
                kind = .remoteBranch(remote: String(remote))
            } else if name.hasPrefix("refs/tags/") {
                kind = .tag
            } else {
                kind = .other
            }
            let track = parseTrack(f[4])
            return Ref(name: name, kind: kind, target: f[1], peeledTarget: f[2].isEmpty ? nil : f[2],
                       upstream: f[3].isEmpty ? nil : f[3], ahead: track.ahead, behind: track.behind,
                       upstreamGone: track.gone, isHead: f[5] == "*", symbolicTarget: f[6].isEmpty ? nil : f[6])
        }
    }

    /// Parses `ahead 2, behind 1`, `ahead 3`, `gone` or an empty string.
    static func parseTrack(_ text: String) -> (ahead: Int, behind: Int, gone: Bool) {
        var ahead = 0, behind = 0
        if text == "gone" { return (0, 0, true) }
        for part in text.components(separatedBy: ", ") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = count } else if words[0] == "behind" { behind = count }
        }
        return (ahead, behind, false)
    }
}

/// Parses `git config -z --get-regexp '^remote\.'` into remotes.
public enum RemoteParser {
    public static func parse(_ data: Data) -> [Remote] {
        var remotes: [String: Remote] = [:]
        var order: [String] = []
        for entry in data.nulSeparatedFields() {
            // Each entry is "key\nvalue"; a key with no value has no newline.
            let key = entry.prefix { $0 != "\n" }
            let value = entry.count > key.count ? String(entry.dropFirst(key.count + 1)) : ""
            guard key.hasPrefix("remote."), let dot = key.lastIndex(of: ".") else { continue }
            let nameStart = key.index(key.startIndex, offsetBy: "remote.".count)
            guard nameStart < dot else { continue }
            let name = String(key[nameStart..<dot])
            let variable = key[key.index(after: dot)...].lowercased()
            if remotes[name] == nil {
                remotes[name] = Remote(name: name)
                order.append(name)
            }
            switch variable {
            case "url": remotes[name]?.fetchURL = value
            case "pushurl": remotes[name]?.pushURLs.append(value)
            default: break
            }
        }
        return order.compactMap { remotes[$0] }.filter { $0.fetchURL != nil || !$0.pushURLs.isEmpty }
    }
}

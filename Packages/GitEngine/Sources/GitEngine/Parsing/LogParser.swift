import Foundation

/// Builds the `git log` format and parses its NUL-separated output.
public enum LogParser {
    /// Hash, parents, author name/email/time, committer name/email/time, decorations, raw message.
    static let placeholders = ["%H", "%P", "%an", "%ae", "%at", "%cn", "%ce", "%ct", "%D", "%B"]
    static var width: Int { placeholders.count }

    /// Used with `-z` and `--decorate=full`, so each record is these fields separated by NUL and terminated by NUL.
    public static let format = "tformat:" + placeholders.joined(separator: "%x00")

    public static func parse(_ data: Data) throws -> [Commit] {
        let fields = data.nulSeparatedFields()
        guard fields.count % width == 0 else {
            throw GitError.unexpectedOutput("log returned \(fields.count) fields, not a multiple of \(width)")
        }
        return try stride(from: 0, to: fields.count, by: width).map { start in
            try commit(from: fields[start..<start + width])
        }
    }

    /// One commit from exactly `width` fields.
    static func commit(from slice: ArraySlice<String>) throws -> Commit {
        let f = Array(slice)
        guard f.count == width, f[0].count >= 40, f[0].allSatisfy(\.isHexDigit),
              let authorTime = TimeInterval(f[4]), let committerTime = TimeInterval(f[7]) else {
            throw GitError.unexpectedOutput("log record for \(f.first?.prefix(40) ?? "")")
        }
        var message = f[9]
        while message.hasSuffix("\n") { message.removeLast() }
        return Commit(
            id: f[0],
            parents: f[1].split(separator: " ").map(String.init),
            author: Signature(name: f[2], email: f[3], date: Date(timeIntervalSince1970: authorTime)),
            committer: Signature(name: f[5], email: f[6], date: Date(timeIntervalSince1970: committerTime)),
            message: message,
            decorations: f[8].isEmpty ? [] : f[8].components(separatedBy: ", ").map(Decoration.init(parsing:))
        )
    }
}

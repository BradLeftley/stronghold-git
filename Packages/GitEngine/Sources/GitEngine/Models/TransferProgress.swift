import Foundation

/// One progress update from a fetch, pull or push, such as "Receiving objects: 45% (45/100)".
public struct TransferProgress: Sendable, Equatable {
    /// What git is doing: "Receiving objects", "Resolving deltas", "Writing objects"…
    public var phase: String
    public var percent: Int
    public var current: Int
    public var total: Int
    /// Trailing detail such as "1.2 MiB | 1.0 MiB/s", empty when git printed none.
    public var detail: String

    /// 0...1.
    public var fraction: Double { Double(max(0, min(100, percent))) / 100 }

    public init(phase: String, percent: Int, current: Int, total: Int, detail: String = "") {
        self.phase = phase
        self.percent = percent
        self.current = current
        self.total = total
        self.detail = detail
    }

    /// "Receiving objects 45% · 1.2 MiB | 1.0 MiB/s"
    public var summary: String {
        var text = "\(phase) \(percent)%"
        if !detail.isEmpty { text += " · \(detail)" }
        return text
    }
}

/// Reads git's `--progress` lines. Anything that isn't a percentage line returns nil.
public enum ProgressParser {
    public static func parse(_ line: String) -> TransferProgress? {
        var text = Substring(line)
        if text.hasPrefix("remote: ") { text = text.dropFirst("remote: ".count) }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let phase = text[..<colon].trimmingCharacters(in: .whitespaces)
        guard !phase.isEmpty, phase.allSatisfy({ $0.isLetter || $0 == " " }) else { return nil }
        // "  45% (45/100), 1.2 MiB | 1.0 MiB/s, done."
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard let percentEnd = rest.firstIndex(of: "%"), let percent = Int(rest[..<percentEnd]) else { return nil }
        let afterPercent = rest[rest.index(after: percentEnd)...].trimmingCharacters(in: .whitespaces)
        guard afterPercent.hasPrefix("("), let close = afterPercent.firstIndex(of: ")") else { return nil }
        let counts = afterPercent[afterPercent.index(after: afterPercent.startIndex)..<close].split(separator: "/")
        guard counts.count == 2, let current = Int(counts[0]), let total = Int(counts[1]) else { return nil }
        var detail = afterPercent[afterPercent.index(after: close)...].trimmingCharacters(in: CharacterSet(charactersIn: ", ."))
        if detail.hasSuffix(", done") { detail.removeLast(6) }
        if detail == "done" { detail = "" }
        return TransferProgress(phase: phase, percent: percent, current: current, total: total, detail: detail)
    }
}

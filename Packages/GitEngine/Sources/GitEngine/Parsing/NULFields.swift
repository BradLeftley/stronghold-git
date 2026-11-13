import Foundation

extension Data {
    /// Splits NUL-separated git output into fields. A trailing NUL terminator does not produce an
    /// empty final field.
    func nulSeparatedFields() -> [String] {
        var fields = split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        if fields.last == "" { fields.removeLast() }
        return fields
    }
}

/// Undoes git's C-style path quoting (`"a\tb"`, `"caf\303\251"`), used where `-z` isn't available.
enum GitPathUnquoter {
    static func unquote(_ text: Substring) -> String {
        guard text.count >= 2, text.first == "\"", text.last == "\"" else { return String(text) }
        var bytes: [UInt8] = []
        var iterator = Array(text.dropFirst().dropLast().utf8).makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\\") else { bytes.append(byte); continue }
            guard let escaped = iterator.next() else { bytes.append(byte); break }
            switch escaped {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(escaped - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = iterator.next() else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(escaped)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

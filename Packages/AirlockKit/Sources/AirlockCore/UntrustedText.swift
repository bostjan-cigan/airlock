import Foundation

/// Text that came from inside a container: written by the agent, or by code it ran. It's
/// shown in the app and relayed to the chat that handed the task off, so it must not be able
/// to hide parts of itself, rewrite the terminal, or pass for AIrlock's own output.
public enum UntrustedText {
    /// Removes terminal escape sequences, control characters (newlines and tabs stay),
    /// invisible and direction-changing characters, and Unicode tag characters.
    public static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if scalar == "\u{1B}" {
                skipEscape(&scalars)
                continue
            }
            if isAllowed(scalar) { out.append(scalar) }
        }
        return String(out)
    }

    /// First non-empty line, cleaned and capped: one line of output can't start another.
    public static func oneLine(_ text: String, limit: Int = 200) -> String {
        let line = clean(text).split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let flat = line.replacingOccurrences(of: "\t", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// Cleaned and capped, keeping lines.
    public static func block(_ text: String, limit: Int) -> String {
        let cleaned = clean(text)
        return cleaned.count > limit ? String(cleaned.prefix(limit)) + "\n…(truncated)" : cleaned
    }

    static func isAllowed(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0A, 0x09: return true
        case 0x00...0x1F, 0x7F...0x9F: return false        // C0 and C1 controls (CR included)
        case 0x200B...0x200F, 0x2028...0x202E: return false // zero-width, line/paragraph separators, bidi embedding
        case 0x2060...0x206F: return false                  // word joiner, invisible operators, bidi isolates
        case 0xFEFF, 0xFFF9...0xFFFB: return false           // byte-order mark, interlinear annotations
        case 0xE0000...0xE007F: return false                 // tag characters (invisible text)
        default: return true
        }
    }

    /// Skips the rest of an escape sequence (CSI, OSC, or a two-character one).
    static func skipEscape(_ scalars: inout String.UnicodeScalarView.Iterator) {
        guard let next = scalars.next() else { return }
        switch next {
        case "[":
            // CSI: parameters, then one final byte in 0x40...0x7E.
            while let c = scalars.next(), !(0x40...0x7E).contains(c.value) {}
        case "]", "P", "X", "^", "_":
            // OSC/DCS/SOS/PM/APC: until BEL or ESC \.
            while let c = scalars.next() {
                if c == "\u{07}" { break }
                if c == "\u{1B}" { _ = scalars.next(); break }
            }
        default:
            break
        }
    }

    /// A hostname as the agent's DNS lookups report it: letters, digits, hyphens and dots,
    /// labels up to 63 characters, at most 253 in all. Anything else isn't shown or relayed.
    public static func isHostname(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 253, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else {
            return false
        }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }
    }
}

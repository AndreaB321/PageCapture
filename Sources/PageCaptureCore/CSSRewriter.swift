import Foundation

/// Pure rewriting of a stylesheet's references (for the self-contained HTML): `@import` rules and
/// `url()`s, resolved against the stylesheet's own URL. `data:` and fragment-only (`#id`) URLs are
/// left as they are. Comments and strings are skipped.
public enum CSSRewriter {
    public struct References: Equatable, Sendable {
        /// What `@import` rules load, in order.
        public var imports: [URL] = []
        /// What the other `url()`s reference, in order, without repeats.
        public var resources: [URL] = []
    }

    public static func references(in css: String, base: URL) -> References {
        var refs = References()
        _ = scan(css, base: base, importRule: { url, _ in
            refs.imports.append(url)
            return ""
        }, resource: { url in
            if !refs.resources.contains(url) { refs.resources.append(url) }
            return ""
        })
        return refs
    }

    /// `css` with each `@import` replaced by `imported(url)` inside the rule's layer, supports and
    /// media conditions (dropped when it returns nil), and every other `url()` by
    /// `url("<resource(url)>")`. A leading `@charset` is dropped.
    public static func rewrite(_ css: String, base: URL, imported: (URL) -> String?,
                               resource: (URL) -> String) -> String {
        scan(css, base: base, importRule: { url, conditions in
            imported(url).map { wrap($0, in: conditions) } ?? ""
        }, resource: { "url(\"\(escape(resource($0)))\")" })
    }

    // MARK: Scanning

    private static func scan(_ css: String, base: URL, importRule: (URL, String) -> String,
                             resource: (URL) -> String) -> String {
        let s = Array(css.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var depth = 0
        if let charset = leadingCharsetEnd(s) { i = charset }
        while i < s.count {
            let c = s[i]
            if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                let end = commentEnd(s, from: i)
                out.append(contentsOf: s[i..<end])
                i = end
            } else if c == "\"" || c == "'" {
                let end = stringEnd(s, from: i).end
                out.append(contentsOf: s[i..<end])
                i = end
            } else if c == "@", depth == 0, keyword(s, at: i + 1, "import") {
                var j = i + 7
                var semicolon = j
                while semicolon < s.count, s[semicolon] != ";" {
                    if s[semicolon] == "\"" || s[semicolon] == "'" { semicolon = stringEnd(s, from: semicolon).end } else { semicolon += 1 }
                }
                skipSpace(s, &j)
                var raw: String?
                if j < s.count, s[j] == "\"" || s[j] == "'" {
                    let string = stringEnd(s, from: j)
                    raw = string.value
                    j = string.end
                } else if keyword(s, at: j, "url(") {
                    let token = urlToken(s, from: j)
                    raw = token.value
                    j = token.end
                }
                let conditions = String(String.UnicodeScalarView(s[min(j, semicolon)..<semicolon]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let raw, let url = resolve(raw, base: base) {
                    out.append(contentsOf: importRule(url, conditions).unicodeScalars)
                } else {
                    out.append(contentsOf: s[i..<min(semicolon + 1, s.count)])
                }
                i = min(semicolon + 1, s.count)
            } else if c == "u" || c == "U", keyword(s, at: i, "url("), i == 0 || !isNameCharacter(s[i - 1]) {
                let token = urlToken(s, from: i)
                if let url = resolve(token.value, base: base) {
                    out.append(contentsOf: resource(url).unicodeScalars)
                } else {
                    out.append(contentsOf: s[i..<token.end])
                }
                i = token.end
            } else {
                if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) }
                out.append(c)
                i += 1
            }
        }
        return String(out)
    }

    /// `@import` conditions: `layer` / `layer(name)`, `supports(…)`, then a media query list.
    static func wrap(_ css: String, in conditions: String) -> String {
        var rest = Substring(conditions)
        var layer: String?
        var supports: String?
        if rest.lowercased().hasPrefix("layer(") , let close = rest.firstIndex(of: ")") {
            layer = String(rest[rest.index(rest.startIndex, offsetBy: 6)..<close])
            rest = rest[rest.index(after: close)...]
        } else if rest.lowercased() == "layer" || rest.lowercased().hasPrefix("layer ") {
            layer = ""
            rest = rest.dropFirst(5)
        }
        rest = rest.drop { $0.isWhitespace }
        if rest.lowercased().hasPrefix("supports(") {
            var level = 0
            var end = rest.startIndex
            for index in rest.indices {
                if rest[index] == "(" { level += 1 } else if rest[index] == ")" { level -= 1 }
                if level == 0, rest[index] == ")" { end = index; break }
            }
            supports = String(rest[rest.index(rest.startIndex, offsetBy: 8)...end])
            rest = rest[rest.index(after: end)...]
        }
        let media = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = css
        if !media.isEmpty { text = "@media \(media) {\n\(text)\n}" }
        if let supports { text = "@supports \(supports) {\n\(text)\n}" }
        if let layer { text = "@layer\(layer.isEmpty ? "" : " " + layer) {\n\(text)\n}" }
        return text
    }

    private static func resolve(_ raw: String, base: URL) -> URL? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw.hasPrefix("#") || raw.lowercased().hasPrefix("data:") { return nil }
        let url = URL(string: raw, relativeTo: base)
            ?? raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(["%", "#"]))
                .flatMap { URL(string: $0, relativeTo: base) }
        return url?.absoluteURL
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\a ")
    }

    private static func isNameCharacter(_ c: Unicode.Scalar) -> Bool {
        c == "-" || c == "_" || c == "\\" || c.properties.isAlphabetic || ("0"..."9").contains(c) || !c.isASCII
    }

    private static func keyword(_ s: [Unicode.Scalar], at index: Int, _ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        guard index + scalars.count <= s.count else { return false }
        for (offset, w) in scalars.enumerated() where Character(s[index + offset]).lowercased() != Character(w).lowercased() {
            return false
        }
        return word.hasSuffix("(") || index + scalars.count == s.count || !isNameCharacter(s[index + scalars.count])
    }

    private static func skipSpace(_ s: [Unicode.Scalar], _ i: inout Int) {
        while i < s.count, s[i].properties.isWhitespace { i += 1 }
    }

    private static func commentEnd(_ s: [Unicode.Scalar], from i: Int) -> Int {
        var j = i + 2
        while j + 1 < s.count, !(s[j] == "*" && s[j + 1] == "/") { j += 1 }
        return min(j + 2, s.count)
    }

    /// A quoted string starting at `i`: its unescaped value and the index after its closing quote.
    private static func stringEnd(_ s: [Unicode.Scalar], from i: Int) -> (value: String, end: Int) {
        let quote = s[i]
        var value = String.UnicodeScalarView()
        var j = i + 1
        while j < s.count, s[j] != quote, s[j] != "\n" {
            if s[j] == "\\", j + 1 < s.count {
                j += 1
                if s[j] != "\n" { value.append(s[j]) }
            } else {
                value.append(s[j])
            }
            j += 1
        }
        return (String(value), min(j + 1, s.count))
    }

    /// `url(…)` starting at `i` (quoted or not): its value and the index after the `)`.
    private static func urlToken(_ s: [Unicode.Scalar], from i: Int) -> (value: String, end: Int) {
        var j = i + 4
        skipSpace(s, &j)
        var value: String
        if j < s.count, s[j] == "\"" || s[j] == "'" {
            let string = stringEnd(s, from: j)
            value = string.value
            j = string.end
        } else {
            var raw = String.UnicodeScalarView()
            while j < s.count, s[j] != ")" { raw.append(s[j]); j += 1 }
            value = String(raw)
        }
        while j < s.count, s[j] != ")" { j += 1 }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value, min(j + 1, s.count))
    }

    private static func leadingCharsetEnd(_ s: [Unicode.Scalar]) -> Int? {
        var i = 0
        if i < s.count, s[i] == "\u{FEFF}" { i += 1 }
        guard keyword(s, at: i, "@charset") else { return i > 0 ? i : nil }
        while i < s.count, s[i] != ";" { i += 1 }
        return min(i + 1, s.count)
    }
}

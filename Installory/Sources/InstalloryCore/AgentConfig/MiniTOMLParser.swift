import Foundation

/// A parsed TOML value. Only the subset needed to read agent config files.
enum TOMLValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])
    /// A value this parser does not model (dates, odd numbers); kept as raw text.
    case other(String)

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var tableValue: [String: TOMLValue]? {
        if case .table(let value) = self { return value }
        return nil
    }

    var arrayValue: [TOMLValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Converts scalars to display text (strings verbatim, numbers/bools formatted).
    var scalarText: String? {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .other(let value): value
        case .array, .table: nil
        }
    }
}

/// A deliberately small, forgiving TOML reader.
///
/// Supports: `[table]` and dotted `[a.b."c d"]` headers, `[[array.of.tables]]`,
/// dotted keys, bare/quoted keys, basic strings with escapes, literal strings,
/// multi-line basic/literal strings, integers (incl. `_`, hex/octal/binary),
/// floats, booleans, arrays (multi-line, trailing commas, comments), inline
/// tables, and `#` comments. Anything it cannot understand is skipped line by
/// line and counted in `issues`; it never throws.
struct MiniTOMLParser {
    struct Result: Sendable, Equatable {
        let root: [String: TOMLValue]
        /// Number of lines that could not be parsed and were skipped.
        let issues: Int
    }

    private enum PathStep: Equatable {
        case key(String)
        case lastElement
    }

    private var scalars: [Unicode.Scalar]
    private var index = 0
    private var root: [String: TOMLValue] = [:]
    private var currentTable: [PathStep] = []
    private var issues = 0
    private let maximumDepth = 32

    private init(text: String) {
        scalars = Array(text.unicodeScalars)
    }

    static func parse(_ text: String) -> Result {
        var parser = MiniTOMLParser(text: text)
        parser.run()
        return Result(root: parser.root, issues: parser.issues)
    }

    // MARK: - Driver

    private mutating func run() {
        // Skip a UTF-8 BOM if present.
        if peek() == "\u{FEFF}" { index += 1 }
        while index < scalars.count {
            skipWhitespaceCommentsAndNewlines()
            guard index < scalars.count else { break }
            let lineStart = index
            let succeeded: Bool
            if peek() == "[" {
                succeeded = parseHeader()
            } else {
                succeeded = parseKeyValueLine()
            }
            if !succeeded {
                issues += 1
                index = lineStart
                skipToNextLine()
            }
        }
    }

    private mutating func parseHeader() -> Bool {
        let isArrayTable = peek(offset: 1) == "["
        index += isArrayTable ? 2 : 1
        skipInlineWhitespace()
        guard let keys = parseKeyPath(), !keys.isEmpty else { return false }
        skipInlineWhitespace()
        guard consume("]") else { return false }
        if isArrayTable { guard consume("]") else { return false } }
        guard expectEndOfLine() else { return false }

        if isArrayTable {
            // Ensure the parent path exists, then append a new table.
            let parentSteps = steps(for: Array(keys.dropLast()))
            let last = keys[keys.count - 1]
            var appended = false
            mutateTable(at: parentSteps) { table in
                switch table[last] {
                case .array(var items):
                    items.append(.table([:]))
                    table[last] = .array(items)
                    appended = true
                case nil:
                    table[last] = .array([.table([:])])
                    appended = true
                default:
                    appended = false
                }
            }
            guard appended else { return false }
            currentTable = parentSteps + [.key(last), .lastElement]
        } else {
            let tableSteps = steps(for: keys)
            mutateTable(at: tableSteps) { _ in }
            currentTable = tableSteps
        }
        return true
    }

    /// Maps a dotted header to path steps, descending into the last element of
    /// any array-of-tables already present along the way.
    private func steps(for keys: [String]) -> [PathStep] {
        var result: [PathStep] = []
        var node: TOMLValue? = .table(root)
        for key in keys {
            result.append(.key(key))
            guard case .table(let table)? = node else { node = nil; continue }
            let child = table[key]
            if case .array(let items)? = child, case .table? = items.last {
                result.append(.lastElement)
                node = items.last
            } else {
                node = child
            }
        }
        return result
    }

    private mutating func parseKeyValueLine() -> Bool {
        guard let keys = parseKeyPath(), !keys.isEmpty else { return false }
        skipInlineWhitespace()
        guard consume("=") else { return false }
        skipInlineWhitespace()
        guard let value = parseValue(depth: 0) else { return false }
        guard expectEndOfLine() else { return false }
        let parentSteps = currentTable + keys.dropLast().map { PathStep.key($0) }
        let last = keys[keys.count - 1]
        mutateTable(at: parentSteps) { table in
            table[last] = value
        }
        return true
    }

    // MARK: - Tree mutation

    private mutating func mutateTable(
        at steps: [PathStep],
        _ body: (inout [String: TOMLValue]) -> Void
    ) {
        Self.mutate(&root, steps: steps[...], body)
    }

    private static func mutate(
        _ table: inout [String: TOMLValue],
        steps: ArraySlice<PathStep>,
        _ body: (inout [String: TOMLValue]) -> Void
    ) {
        guard let first = steps.first else {
            body(&table)
            return
        }
        guard case .key(let key) = first else { return }
        let rest = steps.dropFirst()
        if rest.first == .lastElement {
            guard case .array(var items)? = table[key], !items.isEmpty,
                  case .table(var inner) = items[items.count - 1] else { return }
            mutate(&inner, steps: rest.dropFirst(), body)
            items[items.count - 1] = .table(inner)
            table[key] = .array(items)
            return
        }
        var inner: [String: TOMLValue]
        switch table[key] {
        case .table(let existing)?: inner = existing
        case nil: inner = [:]
        default: return // A scalar already lives here; ignore the conflicting write.
        }
        mutate(&inner, steps: rest, body)
        table[key] = .table(inner)
    }

    // MARK: - Keys

    private mutating func parseKeyPath() -> [String]? {
        var keys: [String] = []
        while true {
            skipInlineWhitespace()
            guard let key = parseKey() else { return nil }
            keys.append(key)
            skipInlineWhitespace()
            if peek() == "." {
                index += 1
                continue
            }
            return keys
        }
    }

    private mutating func parseKey() -> String? {
        switch peek() {
        case "\"": return parseBasicString()
        case "'": return parseLiteralString()
        default:
            var key = ""
            while let scalar = peek(), Self.isBareKeyScalar(scalar) {
                key.unicodeScalars.append(scalar)
                index += 1
            }
            return key.isEmpty ? nil : key
        }
    }

    private static func isBareKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
        default: false
        }
    }

    // MARK: - Values

    private mutating func parseValue(depth: Int) -> TOMLValue? {
        guard depth < maximumDepth, let scalar = peek() else { return nil }
        switch scalar {
        case "\"":
            if peek(offset: 1) == "\"", peek(offset: 2) == "\"" {
                return parseMultilineBasicString().map(TOMLValue.string)
            }
            return parseBasicString().map(TOMLValue.string)
        case "'":
            if peek(offset: 1) == "'", peek(offset: 2) == "'" {
                return parseMultilineLiteralString().map(TOMLValue.string)
            }
            return parseLiteralString().map(TOMLValue.string)
        case "[":
            return parseArray(depth: depth)
        case "{":
            return parseInlineTable(depth: depth)
        default:
            return parseBareValue()
        }
    }

    private mutating func parseArray(depth: Int) -> TOMLValue? {
        index += 1 // [
        var items: [TOMLValue] = []
        while true {
            skipWhitespaceCommentsAndNewlines()
            if consume("]") { return .array(items) }
            guard let value = parseValue(depth: depth + 1) else { return nil }
            items.append(value)
            skipWhitespaceCommentsAndNewlines()
            if consume(",") { continue }
            if consume("]") { return .array(items) }
            return nil
        }
    }

    private mutating func parseInlineTable(depth: Int) -> TOMLValue? {
        index += 1 // {
        var table: [String: TOMLValue] = [:]
        while true {
            // Inline tables are single-line in TOML 1.0, but be forgiving.
            skipWhitespaceCommentsAndNewlines()
            if consume("}") { return .table(table) }
            guard let keys = parseKeyPath(), !keys.isEmpty else { return nil }
            skipInlineWhitespace()
            guard consume("=") else { return nil }
            skipInlineWhitespace()
            guard let value = parseValue(depth: depth + 1) else { return nil }
            Self.mutate(&table, steps: keys.dropLast().map { PathStep.key($0) }[...]) { inner in
                inner[keys[keys.count - 1]] = value
            }
            skipWhitespaceCommentsAndNewlines()
            if consume(",") { continue }
            if consume("}") { return .table(table) }
            return nil
        }
    }

    private mutating func parseBareValue() -> TOMLValue? {
        var token = ""
        while let scalar = peek(),
              !(scalar == "," || scalar == "]" || scalar == "}" || scalar == "#"
                || scalar == "\n" || scalar == "\r") {
            token.unicodeScalars.append(scalar)
            index += 1
        }
        token = token.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return nil }
        if token == "true" { return .bool(true) }
        if token == "false" { return .bool(false) }
        let cleaned = token.replacingOccurrences(of: "_", with: "")
        if let integer = Self.parseInteger(cleaned) { return .integer(integer) }
        if let double = Double(cleaned), cleaned.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) {
            return .double(double)
        }
        if ["inf", "+inf", "-inf", "nan", "+nan", "-nan"].contains(cleaned) { return .other(token) }
        // Dates and times: first character must be a digit.
        if let first = token.unicodeScalars.first, ("0"..."9").contains(first) {
            return .other(token)
        }
        return nil
    }

    private static func parseInteger(_ text: String) -> Int? {
        if text.hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16) }
        if text.hasPrefix("0o") { return Int(text.dropFirst(2), radix: 8) }
        if text.hasPrefix("0b") { return Int(text.dropFirst(2), radix: 2) }
        return Int(text)
    }

    // MARK: - Strings

    private mutating func parseBasicString() -> String? {
        index += 1 // "
        var result = ""
        while let scalar = peek() {
            index += 1
            switch scalar {
            case "\"":
                return result
            case "\\":
                guard let escaped = parseEscape() else { return nil }
                result.unicodeScalars.append(contentsOf: escaped.unicodeScalars)
            case "\n", "\r":
                return nil
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return nil
    }

    private mutating func parseMultilineBasicString() -> String? {
        index += 3
        // A newline immediately after the opening delimiter is trimmed.
        if peek() == "\r" { index += 1 }
        if peek() == "\n" { index += 1 }
        var result = ""
        while let scalar = peek() {
            if scalar == "\"", peek(offset: 1) == "\"", peek(offset: 2) == "\"" {
                // Up to two extra quotes before the closing delimiter are content.
                var run = 0
                while peek(offset: run) == "\"" { run += 1 }
                let contentQuotes = min(run - 3, 2)
                for _ in 0..<contentQuotes { result.unicodeScalars.append("\"") }
                index += contentQuotes + 3
                return result
            }
            index += 1
            if scalar == "\\" {
                // Line-ending backslash: trim the newline and leading whitespace.
                if let next = peek(), next == "\n" || next == "\r" || next == " " || next == "\t" {
                    var lookahead = index
                    while lookahead < scalars.count, scalars[lookahead] == " " || scalars[lookahead] == "\t" {
                        lookahead += 1
                    }
                    if lookahead < scalars.count, scalars[lookahead] == "\n" || scalars[lookahead] == "\r" {
                        index = lookahead
                        while let ws = peek(), ws == " " || ws == "\t" || ws == "\n" || ws == "\r" {
                            index += 1
                        }
                        continue
                    }
                }
                guard let escaped = parseEscape() else { return nil }
                result.unicodeScalars.append(contentsOf: escaped.unicodeScalars)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return nil
    }

    private mutating func parseLiteralString() -> String? {
        index += 1 // '
        var result = ""
        while let scalar = peek() {
            index += 1
            if scalar == "'" { return result }
            if scalar == "\n" || scalar == "\r" { return nil }
            result.unicodeScalars.append(scalar)
        }
        return nil
    }

    private mutating func parseMultilineLiteralString() -> String? {
        index += 3
        if peek() == "\r" { index += 1 }
        if peek() == "\n" { index += 1 }
        var result = ""
        while let scalar = peek() {
            if scalar == "'", peek(offset: 1) == "'", peek(offset: 2) == "'" {
                var run = 0
                while peek(offset: run) == "'" { run += 1 }
                let contentQuotes = min(run - 3, 2)
                for _ in 0..<contentQuotes { result.unicodeScalars.append("'") }
                index += contentQuotes + 3
                return result
            }
            result.unicodeScalars.append(scalar)
            index += 1
        }
        return nil
    }

    /// Parses the character(s) after a backslash; `index` points just past it.
    private mutating func parseEscape() -> String? {
        guard let scalar = peek() else { return nil }
        index += 1
        switch scalar {
        case "b": return "\u{08}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "e": return "\u{1B}"
        case "\"": return "\""
        case "\\": return "\\"
        case "u": return parseUnicodeEscape(length: 4)
        case "U": return parseUnicodeEscape(length: 8)
        default: return nil
        }
    }

    private mutating func parseUnicodeEscape(length: Int) -> String? {
        guard index + length <= scalars.count else { return nil }
        var hex = ""
        for offset in 0..<length { hex.unicodeScalars.append(scalars[index + offset]) }
        index += length
        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
        return String(Character(scalar))
    }

    // MARK: - Lexing helpers

    private func peek(offset: Int = 0) -> Unicode.Scalar? {
        let position = index + offset
        return position < scalars.count ? scalars[position] : nil
    }

    private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        guard peek() == scalar else { return false }
        index += 1
        return true
    }

    private mutating func skipInlineWhitespace() {
        while let scalar = peek(), scalar == " " || scalar == "\t" { index += 1 }
    }

    private mutating func skipWhitespaceCommentsAndNewlines() {
        while let scalar = peek() {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                index += 1
            } else if scalar == "#" {
                skipToNextLine()
            } else {
                return
            }
        }
    }

    /// After a value or header, allows trailing whitespace and a comment.
    private mutating func expectEndOfLine() -> Bool {
        skipInlineWhitespace()
        guard let scalar = peek() else { return true }
        if scalar == "#" { skipToNextLine(); return true }
        if scalar == "\n" || scalar == "\r" { return true }
        return false
    }

    private mutating func skipToNextLine() {
        while let scalar = peek(), scalar != "\n" { index += 1 }
        if peek() == "\n" { index += 1 }
    }
}

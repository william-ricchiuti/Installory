import Foundation

/// One set of rules for finding credentials in free text, shared by the AI
/// Setup audit (hook commands, allow rules, arguments) and Install History
/// (shell and agent commands). Keeping one core means a shape caught in one
/// place is caught in the other.
///
/// Rules run in order, each replacing only the secret part so the command
/// stays readable (`curl -H "X-Api-Key: ••••" https://api.example.com`).
enum SecretRedaction {
    // MARK: - Key names

    /// Name segments that mark a credential (`OPENAI_API_KEY`, `DB_PASS`,
    /// `apiKey`, `X-Auth-Token`, `GH_PAT`).
    private static let secretSegments: Set<String> = [
        "KEY", "APIKEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS", "PWD",
        "AUTH", "AUTHORIZATION", "CREDENTIAL", "CREDENTIALS", "COOKIE", "PRIVATE",
        "WEBHOOK", "DSN", "PAT", "BEARER", "PASSPHRASE",
    ]

    /// Splits a key name into upper-cased segments on `_`, `-`, `.`, spaces
    /// and camelCase boundaries: `xApiKey` → [X, API, KEY].
    static func nameSegments(_ name: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var previousWasLower = false
        for character in name {
            if character == "_" || character == "-" || character == "." || character == " " || character == ":" {
                if !current.isEmpty { segments.append(current.uppercased()) }
                current = ""
                previousWasLower = false
                continue
            }
            if character.isUppercase, previousWasLower, !current.isEmpty {
                segments.append(current.uppercased())
                current = ""
            }
            current.append(character)
            previousWasLower = character.isLowercase || character.isNumber
        }
        if !current.isEmpty { segments.append(current.uppercased()) }
        return segments
    }

    /// True when a key name looks like it holds a credential. Whole segments
    /// only, so `MAX_THINKING_TOKENS`, `GIT_AUTHOR_NAME` and `KEYBOARD_LAYOUT`
    /// don't match; joined forms such as `PGPASS`, `APIKEY` and `ACCESSTOKEN`
    /// do.
    static func isSecretKeyName(_ name: String) -> Bool {
        nameSegments(name).contains { segment in
            if secretSegments.contains(segment) { return true }
            for suffix in ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASS", "PWD"] where segment.count > suffix.count {
                if segment.hasSuffix(suffix), !nonSecretJoinedSegments.contains(segment) { return true }
            }
            return false
        }
    }

    /// Joined words that end like a credential but aren't one.
    private static let nonSecretJoinedSegments: Set<String> = [
        "MONKEY", "HOTKEY", "TURNKEY", "BYPASS", "COMPASS", "SURPASS", "OVERPASS", "PASSPASS",
    ]

    // MARK: - Token formats

    /// Well-known credential formats that are secret wherever they appear.
    static let tokenPattern = [
        #"sk-ant-[A-Za-z0-9_-]{8,}"#,
        #"sk-(?:proj-)?[A-Za-z0-9_-]{16,}"#,
        #"(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,}"#,
        #"gh[pousr]_[A-Za-z0-9]{16,}"#,
        #"github_pat_[A-Za-z0-9_]{16,}"#,
        #"glpat-[A-Za-z0-9_-]{16,}"#,
        #"xox[abposr]-[A-Za-z0-9-]{10,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"AIza[0-9A-Za-z_-]{30,}"#,
        #"npm_[A-Za-z0-9]{30,}"#,
        #"hf_[A-Za-z0-9]{30,}"#,
        #"pypi-[A-Za-z0-9_-]{16,}"#,
        #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
    ].joined(separator: "|")

    /// Webhook URLs whose path is the credential.
    static let webhookPattern =
        #"(?i)(https?://(?:hooks\.slack\.com/services|(?:canary\.|ptb\.)?discord(?:app)?\.com/api/webhooks|[a-z0-9.-]+\.webhook\.office\.com/webhookb2)/)[^\s"'<>]+"#

    static func looksLikeToken(_ value: String) -> Bool {
        matches("(?:\(tokenPattern))", value) || matches(webhookPattern, value)
    }

    // MARK: - Free text

    /// Redacts credentials in a command or message, replacing each secret with
    /// `replacement`.
    static func redact(_ text: String, replacement: String) -> String {
        var value = text
        let r = NSRegularExpression.escapedTemplate(for: replacement)

        // PEM private keys pasted into commands or prompts.
        let privateKeyLabel = replacement == "[REDACTED]" ? "[REDACTED PRIVATE KEY]" : replacement
        value = replacing(
            #"(?is)-----BEGIN [^-\r\n]+ PRIVATE KEY-----.*?-----END [^-\r\n]+ PRIVATE KEY-----"#,
            in: value, with: NSRegularExpression.escapedTemplate(for: privateKeyLabel)
        )
        // Webhook URLs: keep the host, drop the secret path.
        value = replacing(webhookPattern, in: value, with: "$1\(r)")
        // Credentials in URLs: scheme://user:pass@host and scheme://token@host.
        value = replacing(#"(?i)([a-z][a-z0-9+.-]*://)[^\s/@"']+@"#, in: value, with: "$1\(r)@")
        // Authorization schemes (`Bearer abc`, `Basic abc`, `token abc`).
        value = replacing(#"(?i)(\b(?:Bearer|Basic|token)\s+)[A-Za-z0-9._~+/-]{4,}={0,2}"#, in: value, with: "$1\(r)")
        // Credential-carrying flags whose names don't say "password".
        // Each rule looks at most 200 characters past the command name, so a
        // long line can't make the search quadratic.
        value = replacing(#"(?i)(\b(?:curl|wget|http)\b[^\n|;&]{0,200}?\s(?:-u|--user)\s+)([^\s:'"]+):[^\s'"]+"#, in: value, with: "$1$2:\(r)")
        value = replacing(#"(?i)(\b(?:docker|podman|helm|oras)\b[^\n|;&]{0,40}?\blogin\b[^\n|;&]{0,200}?\s(?:-p|--password)[\s=]+)[^\s]+"#, in: value, with: "$1\(r)")
        value = replacing(#"(?i)(\bsshpass\s+-p\s*)[^\s]+"#, in: value, with: "$1\(r)")
        value = replacing(#"(?i)(\bmysql\b[^\n|;&]{0,200}?\s-p)([^\s-][^\s]*)"#, in: value, with: "$1\(r)")

        // Key/value pairs for secret-looking keys, with an optional opening
        // quote before the key (`-H "X-Api-Key: …"`, `{"apiKey": "…"}`) and
        // an optional `--` flag prefix. The key itself is checked by name.
        value = replacingKeyValues(in: value, replacement: replacement)

        // Standalone token formats.
        value = replacing("(?:\(tokenPattern))", in: value, with: r)
        return value
    }

    /// Replaces masked values that still show their first characters
    /// (`abcd…`, as `AgentConfigSecretMasker.mask` produces) with `••••`, for
    /// text that may be copied into a prompt.
    static func hidingMaskedPrefixes(_ text: String) -> String {
        replacing(#"(^|[\s=:"'])[^\s=:"'…]{1,4}…(?=$|[\s"',;)])"#, in: text, with: "$1••••")
    }

    // MARK: - Helpers

    /// Finds `key=value`, `key: value`, quoted forms and `--key value`, and
    /// replaces the value when the key is a credential name.
    private static func replacingKeyValues(in text: String, replacement: String) -> String {
        let boundary = #"(?:^|(?<=[\s,;{(\[&?|"':]))"#
        let value = #"("[^"\r\n]*"|'[^'\r\n]*'|[^\s,;&|}'"]+)"#
        // `KEY=value`, `"key": "value"`, `-H "X-Api-Key: value"`, `--token=value`.
        let assignment = boundary + #"(-{0,2})(["']?)([A-Za-z_][A-Za-z0-9_.-]{0,80})\2\s*(?::(?!//)|=)\s*"# + value
        // `--token value` (a flag followed by its value).
        let flag = boundary + #"(-{1,2})()([A-Za-z_][A-Za-z0-9_.-]{0,80})\s+"# + value
        var result = text
        for pattern in [assignment, flag] {
            result = replacingSecretValues(pattern: pattern, in: result, replacement: replacement)
        }
        return result
    }

    /// Group 3 is the key, group 4 the value.
    private static func replacingSecretValues(pattern: String, in text: String, replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var result = ""
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let key = nsText.substring(with: match.range(at: 3))
            let valueRange = match.range(at: 4)
            let value = nsText.substring(with: valueRange)
            guard isSecretKeyName(key), !isHarmlessValue(value) else { continue }
            result += nsText.substring(with: NSRange(location: cursor, length: valueRange.location - cursor))
            if let quote = value.first, quote == "\"" || quote == "'" {
                result += String(quote) + replacement + String(quote)
            } else {
                result += replacement
            }
            cursor = valueRange.location + valueRange.length
        }
        result += nsText.substring(from: cursor)
        return result
    }

    /// Values that can't be a credential: empty, variable references, plain
    /// booleans and numbers, and values already redacted.
    static func isHarmlessValue(_ raw: String) -> Bool {
        var value = raw
        if let first = value.first, first == "\"" || first == "'", value.count >= 2, value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return true }
        if ["true", "false", "yes", "no", "on", "off", "null", "none"].contains(value.lowercased()) { return true }
        if value.allSatisfy({ $0.isNumber || $0 == "." }) { return true }
        // An auth scheme word whose credential the scheme rule already replaced.
        if ["bearer", "basic", "token"].contains(value.lowercased()) { return true }
        // Only a whole reference is harmless; `${A}secret` still holds a literal.
        // `${NAME:-default}` is excluded: its default is a literal value.
        if matches(#"^(?:\$\{(?:[A-Za-z_][A-Za-z0-9_]*|[a-z]+:[A-Za-z0-9_.-]+)\}|\$[A-Za-z_][A-Za-z0-9_]*|\{(?:env|file):[^}\s]+\})$"#, value) { return true }
        if value.contains("••••") || value.contains("[REDACTED]") { return true }
        return false
    }

    static func matches(_ pattern: String, _ value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    static func replacing(_ pattern: String, in value: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }
}

import Foundation

/// Masks secret-looking values before they are stored anywhere.
///
/// Every function here returns only masked material; callers must never keep
/// the raw input. Masking rule: first 4 characters + "…", or "••••" when the
/// value is shorter than 8 characters. Environment-variable references are not
/// secrets and are returned verbatim so beginners can see where a value comes from.
enum AgentConfigSecretMasker {
    static let shortMask = "••••"

    /// Applies the masking rule to a literal value.
    static func mask(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        guard value.count >= 8 else { return shortMask }
        return String(value.prefix(4)) + "…"
    }

    /// True when a key name looks like it holds a credential.
    static func isSecretKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH"].contains { upper.contains($0) }
    }

    /// True when a value only refers to a variable defined elsewhere, such as
    /// `${GITHUB_TOKEN}`, `$TOKEN`, `${env:TOKEN}`, `${input:token}`,
    /// `{env:TOKEN}` (opencode) or `{file:~/.secret}` (opencode), optionally
    /// with a scheme like `Bearer ${TOKEN}`.
    ///
    /// A value only counts as a reference when nothing meaningful is left once
    /// every reference token is removed: at most one leading auth scheme word
    /// (`Bearer`, `Basic`, `Token`) plus whitespace or separator punctuation.
    /// `hunter2pa$word` or `mypassword${X}` therefore stay literal secrets.
    static func isReference(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard referencePatterns.contains(where: { matches($0, trimmed) }) else { return false }
        var remainder = trimmed
        for pattern in referencePatterns {
            remainder = replacing(pattern, in: remainder, with: " ")
        }
        remainder = remainder.trimmingCharacters(in: .whitespaces)
        if let scheme = remainder.split(separator: " ", maxSplits: 1).first,
           ["bearer", "basic", "token"].contains(scheme.lowercased()) {
            remainder = String(remainder.dropFirst(scheme.count))
        }
        // Separators such as `${USER}:${PASS}` are fine; any letter or digit
        // left over is literal text that may be (part of) a secret.
        return !remainder.contains { $0.isLetter || $0.isNumber }
    }

    /// `${...}` first so `$NAME` doesn't eat the brace form's inside.
    private static let referencePatterns = [
        #"\$\{[^}\s]+\}"#,
        #"\$[A-Za-z_][A-Za-z0-9_]*"#,
        #"\{(?:env|file):[^}\s]+\}"#,
    ]

    /// Well-known credential formats that are secret regardless of key name.
    static func looksLikeToken(_ value: String) -> Bool {
        matches(
            #"(?:sk-[A-Za-z0-9_-]{16,}|sk-ant-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|glpat-[A-Za-z0-9_-]{16,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})"#,
            value
        )
    }

    /// Masks one key/value pair from an `env` or `headers` table.
    static func maskedPair(key: String, value: String) -> MaskedValue {
        if isReference(value) {
            return MaskedValue(key: key, maskedValue: value, isLiteralSecret: false)
        }
        let isSecret = !value.isEmpty && (isSecretKey(key) || looksLikeToken(value))
        return MaskedValue(key: key, maskedValue: mask(value), isLiteralSecret: isSecret)
    }

    /// Masks secret-looking command-line arguments.
    ///
    /// Besides `--api-key`/`--token`-style flags, the value after a
    /// credential-carrying flag (`--header`/`-H`, `-u`/`--user`,
    /// `-p`/`--password`) is masked; for headers only the value part of a
    /// secret-looking header (`Authorization: …`, `X-Api-Key: …`) is masked.
    /// Any other argument that holds a space, an auth scheme or `user:pass@`
    /// goes through `redactCommand`.
    ///
    /// - Returns: the masked arguments and whether any literal secret was found.
    static func maskArguments(_ args: [String]) -> (args: [String], foundSecret: Bool) {
        var result: [String] = []
        var foundSecret = false
        var previousFlag: String?
        for arg in args {
            defer { previousFlag = arg.hasPrefix("-") && !arg.contains("=") ? arg : nil }
            if let flag = previousFlag, !arg.hasPrefix("-") || arg == "-" {
                if let masked = maskCredentialFlagValue(flag: flag, value: arg) {
                    result.append(masked.value)
                    foundSecret = foundSecret || masked.isSecret
                    continue
                }
                if isSecretFlag(flag) {
                    if isReference(arg) {
                        result.append(arg)
                    } else {
                        result.append(mask(arg))
                        foundSecret = foundSecret || !arg.isEmpty
                    }
                    continue
                }
            }
            if arg.hasPrefix("-"), let equals = arg.firstIndex(of: "=") {
                let flag = String(arg[..<equals])
                let value = String(arg[arg.index(after: equals)...])
                if let masked = maskCredentialFlagValue(flag: flag, value: value) {
                    result.append(flag + "=" + masked.value)
                    foundSecret = foundSecret || masked.isSecret
                    continue
                }
                if isSecretKey(flag), !value.isEmpty, !isReference(value) {
                    result.append(flag + "=" + mask(value))
                    foundSecret = true
                    continue
                }
            }
            // KEY=value style arguments (e.g. `docker run -e TOKEN=abc`).
            if !arg.hasPrefix("-"), let equals = arg.firstIndex(of: "="),
               !arg.contains("://") {
                let key = String(arg[..<equals])
                let value = String(arg[arg.index(after: equals)...])
                if isSecretKey(key), !value.isEmpty, !isReference(value),
                   key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                    result.append(key + "=" + mask(value))
                    foundSecret = true
                    continue
                }
            }
            if let sanitizedURL = sanitizedURLArgument(arg) {
                result.append(sanitizedURL.value)
                foundSecret = foundSecret || sanitizedURL.hadCredentials
                continue
            }
            if looksLikeToken(arg) {
                result.append(mask(arg))
                foundSecret = true
                continue
            }
            if !arg.hasPrefix("-"), mayEmbedCredentials(arg) {
                let redacted = redactArgument(arg)
                result.append(redacted)
                foundSecret = foundSecret || redacted != arg
                continue
            }
            result.append(arg)
        }
        return (result, foundSecret)
    }

    /// Extracts only the host from a URL string; never keeps path or query.
    static func host(of urlString: String) -> String? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespaces)),
              let host = components.host, !host.isEmpty else { return nil }
        if let port = components.port { return "\(host):\(port)" }
        return host
    }

    /// True when a URL embeds credentials (`user:pass@`), a secret-named query
    /// parameter with a literal value, or a well-known token format.
    static func urlContainsSecret(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespaces)) else {
            return looksLikeToken(urlString)
        }
        if components.password != nil { return true }
        let secretQuery = (components.queryItems ?? []).contains { item in
            guard let value = item.value, !value.isEmpty, !isReference(value) else { return false }
            return isSecretKey(item.name) || looksLikeToken(value)
        }
        return secretQuery || looksLikeToken(components.path)
    }

    /// Redacts secrets inside a free-form shell command (used for hooks).
    static func redactCommand(_ command: String, maximumLength: Int = 1_024) -> String {
        var value = command
        // Credentials embedded in URLs: scheme://user:pass@host
        value = replacing(#"(?i)([a-z][a-z0-9+.-]*://)[^\s/@]+@"#, in: value, with: "$1••••@")
        // Authorization schemes.
        value = replacing(#"(?i)(\b(?:Bearer|Basic|token)\s+)[A-Za-z0-9._~+/=-]{4,}"#, in: value, with: "$1••••")
        // KEY=value, --key value, --key=value, "key": "value" for secret-looking keys.
        let secretKey = #"[A-Za-z0-9_-]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|AUTH)[A-Za-z0-9_-]*"#
        value = replacing(
            "(?i)((?:^|[\\s;&|(])-{0,2}\(secretKey)\\s*(?:=|:|\\s)\\s*)(\"[^\"]*\"|'[^']*'|[^\\s;&|)]+)",
            in: value,
            with: "$1••••"
        )
        // Query-string secrets in URLs.
        value = replacing(
            "(?i)([?&]\(secretKey)=)[^&\\s\"']+",
            in: value,
            with: "$1••••"
        )
        value = replacing(
            #"(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|glpat-[A-Za-z0-9_-]{16,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})"#,
            in: value,
            with: "••••"
        )
        if value.count > maximumLength {
            value = String(value.prefix(maximumLength)) + "…"
        }
        return value
    }

    // MARK: - Private

    /// Flags whose next argument carries a credential even though the flag
    /// name doesn't say so (curl/http-client style).
    private static let headerFlags: Set<String> = ["--header", "-H"]
    private static let userFlags: Set<String> = ["--user", "-u", "--password", "-p"]

    /// Masks the value of a credential-carrying flag; nil when `flag` isn't one.
    private static func maskCredentialFlagValue(flag: String, value: String) -> (value: String, isSecret: Bool)? {
        if headerFlags.contains(flag) {
            return maskHeaderValue(value)
        }
        guard userFlags.contains(flag) else { return nil }
        if value.isEmpty || isReference(value) { return (value, false) }
        // `-p 8080` / `-p 8080:80/tcp` is far more often a port (mapping) than a password.
        if flag == "-p", matches(#"^[0-9.:\[\]]+(?:/(?:tcp|udp))?$"#, value) { return (value, false) }
        // `user:pass`: keep the user name, mask the password.
        if flag == "-u" || flag == "--user", let colon = value.firstIndex(of: ":") {
            let user = String(value[..<colon])
            let password = String(value[value.index(after: colon)...])
            if password.isEmpty || isReference(password) { return (value, false) }
            // `docker run -u 1000:1000` is uid:gid, not user:password.
            if !user.isEmpty, user.allSatisfy(\.isNumber), password.allSatisfy(\.isNumber) { return (value, false) }
            return (user + ":" + shortMask, true)
        }
        if flag == "-u" || flag == "--user" { return (value, false) }
        return (mask(value), true)
    }

    /// `Name: value` header: masks only the value of secret-looking headers.
    private static func maskHeaderValue(_ header: String) -> (value: String, isSecret: Bool) {
        guard let colon = header.firstIndex(of: ":") else {
            if header.isEmpty || isReference(header) { return (header, false) }
            return (mask(header), true)
        }
        let name = header[..<colon].trimmingCharacters(in: .whitespaces)
        let value = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let secretName = isSecretKey(name) || ["cookie", "proxy-authorization"].contains(name.lowercased())
        guard !value.isEmpty, !isReference(value), secretName || looksLikeToken(value) else {
            return (header, false)
        }
        return (name + ": " + maskHeaderCredential(value), true)
    }

    /// Keeps a leading auth scheme readable: `Bearer abcdef…` → `Bearer ••••`.
    private static func maskHeaderCredential(_ value: String) -> String {
        let parts = value.split(separator: " ", maxSplits: 1)
        if parts.count == 2, ["bearer", "basic", "token"].contains(parts[0].lowercased()) {
            return parts[0] + " " + shortMask
        }
        return mask(value)
    }

    private static func mayEmbedCredentials(_ arg: String) -> Bool {
        arg.contains(" ") || arg.contains("Bearer ") || arg.contains("Basic ")
            || matches(userInfoPattern, arg)
    }

    /// `user:pass@host` without a scheme (URLs with a scheme are handled by
    /// `sanitizedURLArgument`).
    private static let userInfoPattern = #"(?:^|[\s=])[^\s/@:=]+:[^\s/@]+@[^\s@]"#

    private static func redactArgument(_ arg: String) -> String {
        let redacted = redactCommand(arg, maximumLength: .max)
        return replacing(#"(^|[\s=])([^\s/@:=]+:)[^\s/@]+@(?=[^\s@])"#, in: redacted, with: "$1$2••••@")
    }

    private static func isSecretFlag(_ arg: String) -> Bool {
        guard arg.hasPrefix("-"), !arg.contains("=") else { return false }
        let name = arg.drop(while: { $0 == "-" })
        guard !name.isEmpty else { return false }
        return isSecretKey(String(name))
    }

    /// For arguments that are URLs, drops credentials and query strings.
    private static func sanitizedURLArgument(_ arg: String) -> (value: String, hadCredentials: Bool)? {
        guard arg.contains("://"),
              let components = URLComponents(string: arg),
              let scheme = components.scheme,
              let host = components.host else { return nil }
        let hasUserInfo = components.user != nil || components.password != nil
        let hasQuery = !(components.query ?? "").isEmpty
        guard hasUserInfo || hasQuery else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.path.isEmpty ? "" : "/…"
        let secretQuery = (components.queryItems ?? []).contains {
            isSecretKey($0.name) && !($0.value ?? "").isEmpty
        }
        return ("\(scheme)://\(host)\(port)\(path)" + (hasQuery ? "?…" : ""), hasUserInfo || secretQuery)
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    private static func replacing(_ pattern: String, in value: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }
}

import Foundation

/// Quotes one value as a single shell argument.
func shellArgument(_ s: String) -> String {
    guard !s.isEmpty else { return "''" }
    let safeScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
    if s.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) {
        return s
    }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Returns untrusted metadata safe to interpolate into one physical shell-comment line.
///
/// Printable shell metacharacters are inert after `#`, but a line break would end the
/// comment and could turn the remainder into an active command. Control and newline
/// scalars are replaced with ordinary spaces so comments also cannot carry terminal
/// control sequences or Unicode line separators.
func shellCommentText(_ s: String) -> String {
    let unsafeScalars = CharacterSet.controlCharacters.union(.newlines)
    var sanitized = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        if unsafeScalars.contains(scalar) {
            sanitized.append(" ")
        } else {
            sanitized.append(scalar)
        }
    }
    return String(sanitized)
}

/// Escapes characters that are special inside bash double-quoted strings.
func shellDoubleQuoteEscape(_ s: String) -> String {
    s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "`", with: "\\`")
        .replacingOccurrences(of: "$", with: "\\$")
}

/// Wraps `cmd` in a bash `echo` line, escaping characters special inside double quotes.
func shellEchoLine(for cmd: String) -> String {
    // The command itself is shell-quoted by its renderer, but the preview is
    // terminal output. Strip control characters here so hostile local metadata
    // cannot emit terminal escape sequences when the generated script runs.
    let escaped = shellDoubleQuoteEscape(shellCommentText(cmd))
    return "echo \"→ \(escaped)\""
}

/// Explains the subshell wrapper in every generated script header.
let shellSubshellExplanationLines = [
    "#",
    "# Commands run inside a ( ... ) subshell so strict mode (set -euo pipefail)",
    "# never leaks into your Terminal session if you paste this script.",
    "# You can also save it and run: bash <file>.sh",
]

/// Assembles a generated script: header comments stay at the top level (readable,
/// inert), while every executable line runs inside a `( ... )` subshell that turns
/// on strict mode. Pasting the script into an interactive shell therefore cannot
/// leave `set -e`, `set -u`, or `pipefail` enabled in the user's session, and a
/// failing command ends only the subshell, never the Terminal window. The result
/// remains a valid `bash script.sh` program.
func assembleSubshellScript(header: [String], body: [String]) -> String {
    var out = header
    out.append(contentsOf: shellSubshellExplanationLines)
    out.append("(")
    out.append("set -euo pipefail")
    out.append(contentsOf: body)
    out.append(")")
    return out.joined(separator: "\n") + "\n"
}

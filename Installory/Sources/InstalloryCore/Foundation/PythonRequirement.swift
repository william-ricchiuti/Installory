import Foundation

enum PythonRequirement {
    /// Extracts the distribution name from a raw `Requires-Dist` value.
    ///
    /// Follows the PEP 508 name grammar: a name starts and ends with a letter
    /// or digit and may contain `.`, `-` and `_` in between. Everything after
    /// it (extras such as `[socks]`, version specifiers with or without a
    /// separating space or parentheses, environment markers, URL references)
    /// is dropped, so `charset_normalizer<4,>=2`, `requests[socks]>=2.26` and
    /// `idna (>=2.5,<4)` all yield names that match the installed package.
    /// Name comparison (case, `-`/`_`/`.`) is normalised later by
    /// `PackageIdentity.normalizedName`.
    static func distributionName(from requiresDist: String) -> String {
        let trimmed = requiresDist.trimmingCharacters(in: .whitespaces)
        var lastAlphanumeric: String.Index?
        for index in trimmed.indices {
            let character = trimmed[index]
            if character.isASCII, character.isLetter || character.isNumber {
                lastAlphanumeric = index
            } else if character == "." || character == "-" || character == "_" {
                // Allowed inside a name, but never as its first character.
                if lastAlphanumeric == nil { break }
            } else {
                break
            }
        }
        // A trailing separator (as in `name.` before a marker) isn't part of the name.
        guard let lastAlphanumeric else { return "" }
        return String(trimmed[...lastAlphanumeric])
    }
}

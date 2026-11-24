#!/bin/bash
# Checks Installory's product invariants: no subprocesses, no networking,
# read-only access, exactly the approved entitlements, read-only bookmarks.
#
# Usage:
#   scripts/check-invariants.sh                      # source and project checks
#   scripts/check-invariants.sh --binary <App.app>   # also inspect a built app
#
# The source checks are pattern-based tripwires; the binary check looks at what
# the compiled app actually imports, links and embeds, which source tricks
# (typealiases, string-built class names, split lines) can't hide.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SOURCE_DIRS=(Installory/Sources App/Sources)
ENTITLEMENTS="App/Installory.entitlements"

# Files that may write: the app's own data folder and Save-panel destinations.
WRITE_ALLOWED_FILES=(App/Sources/AppCoordinator.swift App/Sources/Views/ScriptSheetView.swift)

# Hosts allowed in URLs embedded in the built app (Settings links, the
# repository link, and the Cargo registry index name the Cargo scanner reads).
ALLOWED_URL_HOSTS=(installory.app github.com index.crates.io apple.com www.apple.com)

fail() {
    echo "✗ $*" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] || fail "Required file is missing: $1"
}

# Prints matches of an extended regex in production Swift source, ignoring
# comments: `// …` line comments and trailing comments, and `/* … */` blocks on
# one line, are removed before the pattern is tested against the code that's
# left. Keeps invariant documentation such as "No Process() calls" from
# failing the check without implementing a full Swift lexer in shell.
#   $1 pattern, $2… files or directories (default: all production source)
code_matches() {
    local pattern="$1"
    shift
    local targets=("$@")
    [ ${#targets[@]} -gt 0 ] || targets=("${SOURCE_DIRS[@]}")
    # The pattern travels through the environment: awk's -v would process its
    # backslash escapes and turn `\(` into a bare `(`.
    # shellcheck disable=SC2016 # the awk program is meant to stay unexpanded
    find "${targets[@]}" -type f -name '*.swift' -print0 \
        | INVARIANT_PATTERN="$pattern" xargs -0 awk '
            BEGIN { pat = ENVIRON["INVARIANT_PATTERN"] }
            {
                code = $0
                gsub(/\/\*[^*]*\*+([^\/*][^*]*\*+)*\//, "", code)   # one-line /* … */ blocks
                sub(/[[:space:]]*\/\/.*$/, "", code)                  # line and trailing // comments
                stripped = code
                sub(/^[[:space:]]*/, "", stripped)
                if (stripped ~ /^\*/ || stripped ~ /^\/\*/) next      # inside a multi-line block comment
                if (code ~ pat) print FILENAME ":" FNR ":" $0
            }'
}

# Fails when `pattern` appears in production code outside `allowed` files.
#   $1 label, $2 pattern, $3… allowed files (optional)
reject_swift_pattern() {
    local label="$1"
    local pattern="$2"
    shift 2
    local matches
    matches="$(code_matches "$pattern")"
    for allowed in "$@"; do
        matches="$(printf '%s\n' "$matches" | grep -v "^${allowed}:" || true)"
    done
    matches="$(printf '%s\n' "$matches" | sed '/^$/d')"
    if [ -n "$matches" ]; then
        echo "✗ $label found in production Swift source:" >&2
        printf '%s\n' "$matches" >&2
        exit 1
    fi
}

matches_pattern() {
    local pattern="$1"
    local file="$2"
    grep -Eq "$pattern" "$file"
}

count_pattern() {
    local pattern="$1"
    local file="$2"
    grep -Ec "$pattern" "$file" || true
}

check_binary() {
    local app="$1"
    local executable
    [ -d "$app" ] || fail "App bundle not found: $app"
    executable="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
    [ -f "$executable" ] || fail "App executable not found: $executable"

    # 1. No subprocess, socket or URL-loading imports.
    local forbidden
    # shellcheck disable=SC2016 # literal $ in the regex
    forbidden="$(nm -u "$executable" | grep -E '^_(posix_spawn|posix_spawnp|fork|vfork|execv|execve|execvp|execvP|execl|execle|execlp|system|popen|socket|connect|getaddrinfo|nw_[a-z_]+|CFStreamCreatePairWithSocket.*|CFSocketCreate.*|CFReadStreamCreateForHTTPRequest|dlopen)$|_OBJC_CLASS_\$_(NSTask|NSURLSession|NSURLConnection|NSURLSessionTask|WKWebView|NSAppleScript|NSUserScriptTask|NSUserUnixTask)$' || true)"
    [ -z "$forbidden" ] || fail "Forbidden imports in the built app:
$forbidden"

    # 2. No networking or web frameworks linked.
    local linked
    linked="$(otool -L "$executable" | grep -E '/(Network|WebKit|CFNetwork|NetworkExtension|SafariServices)\.framework/' || true)"
    [ -z "$linked" ] || fail "Forbidden frameworks linked into the built app:
$linked"

    # 3. Every embedded web address points at an allowed host.
    local host bad=""
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        local ok=0
        for allowed in "${ALLOWED_URL_HOSTS[@]}"; do
            [ "$host" = "$allowed" ] && ok=1
        done
        [ $ok -eq 1 ] || bad="$bad $host"
    done < <(strings -a "$executable" | grep -oE 'https?://[A-Za-z0-9.-]+' | sed -E 's#^https?://##' | sort -u)
    [ -z "$bad" ] || fail "Unexpected web addresses in the built app:$bad"

    # 4. Entitlements. An unsigned build is only ad-hoc (linker) signed and
    #    carries none, so there is nothing to check. Anything that does carry
    #    entitlements, or is signed with a real identity, must have the
    #    approved ones and no network entitlement. Decisions use exit codes,
    #    not tool output: older plutil prints its errors on stdout.
    local entitlements_file signature
    entitlements_file="$(mktemp -t installory-entitlements)"
    # shellcheck disable=SC2064 # expand the path now
    trap "rm -f '$entitlements_file'" EXIT
    codesign -d --entitlements - --xml "$app" >"$entitlements_file" 2>/dev/null || : >"$entitlements_file"
    if [ -s "$entitlements_file" ] && plutil -lint -s "$entitlements_file" >/dev/null 2>&1; then
        for key in com.apple.security.app-sandbox com.apple.security.files.bookmarks.app-scope com.apple.security.files.user-selected.read-write; do
            [ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$entitlements_file" 2>/dev/null)" = "true" ] \
                || fail "Signed app is missing entitlement $key"
        done
        if grep -q 'com\.apple\.security\.network\.' "$entitlements_file"; then
            fail "Signed app has a network entitlement"
        fi
    elif signature="$(codesign -dv "$app" 2>&1)" && ! grep -q '^Signature=adhoc' <<<"$signature"; then
        # Captured first: grep -q closing a pipe early would fail codesign
        # with SIGPIPE under pipefail.
        fail "Signed app has no entitlements; it must be sandboxed"
    else
        echo "  Unsigned (ad-hoc) build without entitlements: entitlement check skipped"
    fi

    echo "✓ Built app passes the binary checks: $app"
}

BINARY_APP=""
if [ "${1:-}" = "--binary" ]; then
    [ -n "${2:-}" ] || fail "Usage: $0 --binary <App.app>"
    BINARY_APP="$2"
fi

command -v grep >/dev/null 2>&1 || fail "grep is required"
command -v find >/dev/null 2>&1 || fail "find is required"
command -v awk >/dev/null 2>&1 || fail "awk is required"
command -v git >/dev/null 2>&1 || fail "git is required"

for directory in "${SOURCE_DIRS[@]}"; do
    [ -d "$directory" ] || fail "Production source directory is missing: $directory"
done

# --- No subprocesses -------------------------------------------------------
# Any use of the Process type (calls, `.init`, typealiases, split lines).
reject_swift_pattern \
    "Process usage" \
    '(^|[^[:alnum:]_.])(Foundation\.)?Process([^[:alnum:]_]|$)'
reject_swift_pattern \
    "Subprocess or dynamic-loading API" \
    '(^|[^[:alnum:]_])(posix_spawnp?|NSTask|NSUserScriptTask|NSUserUnixTask|NSAppleScript|popen|dlopen|dlsym|NSClassFromString)([^[:alnum:]_]|$)|(^|[^[:alnum:]_.])(fork|vfork|execv|execve|execvp|system)[[:space:]]*\('

# --- No networking ---------------------------------------------------------
reject_swift_pattern \
    "Networking API usage" \
    '(^|[^[:alnum:]_])(URLSession|URLRequest|URLProtocol|NWConnection|NWListener|NWBrowser|NWPathMonitor|NWParameters|NWEndpoint|NWProtocol[A-Za-z]*|CFNetwork|CFStream[A-Za-z]*|NSURLConnection|WKWebView|SFSafariViewController|getaddrinfo)([^[:alnum:]_]|$)|^[[:space:]]*import[[:space:]]+(Network|WebKit|SafariServices)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])socket[[:space:]]*\('
reject_swift_pattern \
    "Opening URLs from code (use a SwiftUI Link the user clicks)" \
    'NSWorkspace\.shared\.(open|openApplication)[[:space:]]*\(|(^|[^[:alnum:]_])openURL([^[:alnum:]_]|$)'

# --- Read-only ---------------------------------------------------------------
reject_swift_pattern \
    "File deletion, moves or attribute changes" \
    '(^|[^[:alnum:]_])(removeItem|trashItem|moveItem|copyItem|replaceItem|replaceItemAt|linkItem|createSymbolicLink|setAttributes|createFile|unlink|rmdir)[[:space:]]*\(|FileHandle\([[:space:]]*forWriting|FileHandle\([[:space:]]*forUpdating'
reject_swift_pattern \
    "File writes outside the app's data folder and Save-panel destinations" \
    '(^|[^[:alnum:]_])createDirectory[[:space:]]*\(|\.write\([[:space:]]*to:' \
    "${WRITE_ALLOWED_FILES[@]}"

# --- Project and entitlements --------------------------------------------------
require_file project.yml
require_file "$ENTITLEMENTS"
/usr/bin/plutil -lint "$ENTITLEMENTS" >/dev/null

expected_entitlements=(
    com.apple.security.app-sandbox
    com.apple.security.files.bookmarks.app-scope
    com.apple.security.files.user-selected.read-write
)

for key in "${expected_entitlements[@]}"; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ENTITLEMENTS" 2>/dev/null || true)"
    [ "$value" = "true" ] || fail "Entitlement '$key' must exist and equal true"

    escaped_key="${key//./\\.}"
    matches_pattern "^[[:space:]]*${escaped_key}:[[:space:]]*true[[:space:]]*$" project.yml || \
        fail "project.yml must declare entitlement '$key: true'"
done

entitlement_count="$(/usr/bin/plutil -p "$ENTITLEMENTS" | /usr/bin/grep -c ' => ')"
[ "$entitlement_count" -eq "${#expected_entitlements[@]}" ] || \
    fail "Entitlements changed: expected exactly ${#expected_entitlements[@]} approved keys, found $entitlement_count"

project_entitlement_count="$(count_pattern '^[[:space:]]*com\.apple\.security\.' project.yml)"
[ "${project_entitlement_count:-0}" -eq "${#expected_entitlements[@]}" ] || \
    fail "project.yml entitlement set changed: expected exactly ${#expected_entitlements[@]} approved keys"

# --- Read-only bookmarks ---------------------------------------------------------
# The entitlement authorizes explicit save-panel destinations, but every
# persistent scanning bookmark must remain read-only: exactly one place creates
# bookmarks, and it asks for read-only access.
bookmark_sites="$(code_matches 'bookmarkData[[:space:]]*\(' | sed '/^$/d')"
bookmark_count="$(printf '%s\n' "$bookmark_sites" | sed '/^$/d' | wc -l | tr -d ' ')"
[ "$bookmark_count" -eq 1 ] || fail "Expected exactly one bookmarkData( call site, found $bookmark_count:
$bookmark_sites"
grep -q '^App/Sources/FolderAccessManager.swift:' <<<"$bookmark_sites" || \
    fail "bookmarkData( must only be called in App/Sources/FolderAccessManager.swift"
matches_pattern '\.securityScopeAllowOnlyReadAccess' App/Sources/FolderAccessManager.swift || \
    fail "Scanning bookmarks must retain securityScopeAllowOnlyReadAccess"

require_file scripts/regenerate-xcode.sh
[ -x scripts/regenerate-xcode.sh ] || fail "scripts/regenerate-xcode.sh must be executable"
git check-ignore -q Installory.xcodeproj/__installory_ignore_probe__ || \
    fail "Installory.xcodeproj must remain gitignored; project.yml is the source of truth"
[ -z "$(git ls-files -- 'Installory.xcodeproj/**')" ] || \
    fail "Installory.xcodeproj contains tracked files; project.yml is the source of truth"

echo "✓ Installory product invariants verified"

if [ -n "$BINARY_APP" ]; then
    check_binary "$BINARY_APP"
fi

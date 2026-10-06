import Foundation

/// Bounded, read-only access to agent configuration files through the
/// injectable ``DirectoryAccessProvider``.
///
/// The provider already offers bounded reads and symlink-aware metadata, so the
/// audit reuses it rather than adding a new abstraction. This wrapper adds the
/// three-way outcome the audit needs (missing / read / unreadable-with-reason)
/// and records unreadable files as it goes.
struct AgentConfigFileReader {
    enum Outcome {
        case missing
        case contents(Data)
        case failed(UnreadableConfigFile.Reason)
    }

    let access: any DirectoryAccessProvider
    private(set) var unreadable: [UnreadableConfigFile] = []

    init(access: any DirectoryAccessProvider) {
        self.access = access
    }

    /// Reads at most `maximumBytes` from `url`, following symlinks.
    mutating func read(_ url: URL, maximumBytes: Int) -> Outcome {
        let outcome = Self.read(url, maximumBytes: maximumBytes, access: access)
        if case .failed(let reason) = outcome {
            record(url, reason)
        }
        return outcome
    }

    /// Reads and decodes UTF-8 text. Invalid UTF-8 is reported as invalid format.
    mutating func readText(_ url: URL, maximumBytes: Int) -> String? {
        guard case .contents(let data) = read(url, maximumBytes: maximumBytes) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            record(url, .invalidFormat)
            return nil
        }
        return text
    }

    /// Reads a JSON (or JSONC / JSON5-ish) object. Comments and trailing commas
    /// are tolerated. A file that is not a JSON object is reported as invalid.
    mutating func readJSONObject(_ url: URL, maximumBytes: Int) -> [String: Any]? {
        guard case .contents(let data) = read(url, maximumBytes: maximumBytes) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            // An empty file is treated as "nothing configured", not an error.
            return [:]
        }
        guard let object = Self.parseJSONObject(data) else {
            record(url, .invalidFormat)
            return nil
        }
        return object
    }

    mutating func record(_ url: URL, _ reason: UnreadableConfigFile.Reason) {
        let entry = UnreadableConfigFile(path: url, reason: reason)
        if !unreadable.contains(entry) { unreadable.append(entry) }
    }

    static func parseJSONObject(_ data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        // JSON5 mode accepts // and /* */ comments and trailing commas (JSONC).
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] {
            return object
        }
        return nil
    }

    static func read(_ url: URL, maximumBytes: Int, access: any DirectoryAccessProvider) -> Outcome {
        guard access.fileExists(at: url) else { return .missing }
        let resolved = access.resolvingSymlinks(at: url)
        guard let metadata = try? access.metadata(at: resolved) else { return .failed(.unreadable) }
        switch metadata.kind {
        case .directory:
            return .missing
        case .regularFile, .symbolicLink, .other:
            break
        }
        if let size = metadata.logicalSizeBytes, size > Int64(maximumBytes) {
            return .failed(.tooLarge)
        }
        do {
            let data = try access.data(contentsOf: resolved, maximumBytes: maximumBytes + 1, from: .prefix)
            guard data.count <= maximumBytes else { return .failed(.tooLarge) }
            return .contents(data)
        } catch DirectoryAccessError.readLimitExceeded {
            return .failed(.tooLarge)
        } catch {
            return .failed(.unreadable)
        }
    }
}

// MARK: - JSON plucking helpers

enum AgentConfigJSON {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber where !isBool(number): number.stringValue
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBool(number) else { return nil }
        return number.boolValue
    }

    static func stringArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { string($0) }
    }

    /// Scalar values of a JSON object as strings, sorted by key.
    static func stringPairs(_ value: Any?) -> [(String, String)] {
        guard let object = value as? [String: Any] else { return [] }
        return object.compactMap { key, raw -> (String, String)? in
            if let text = string(raw) { return (key, text) }
            if let flag = bool(raw) { return (key, flag ? "true" : "false") }
            return nil
        }
        .sorted { $0.0 < $1.0 }
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

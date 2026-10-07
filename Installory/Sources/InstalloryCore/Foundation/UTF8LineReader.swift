import Foundation

/// Strictly decodes newline-delimited UTF-8 while containing corruption to the
/// individual line that contains it.
enum UTF8LineReader {
    /// Visits valid UTF-8 lines without constructing a second full-file string
    /// or an intermediate line array. Invalid UTF-8 is contained to one line.
    /// Returning `false` from `body`, or task cancellation, stops the walk.
    static func forEachLine(
        in data: Data,
        _ body: (String) -> Bool
    ) {
        var lineStart = data.startIndex
        var index = lineStart
        var scannedByteCount = 0

        while index < data.endIndex {
            if scannedByteCount.isMultiple(of: 4_096), Task.isCancelled { return }
            let byte = data[index]
            scannedByteCount += 1
            guard byte == 0x0A || byte == 0x0D else {
                index = data.index(after: index)
                continue
            }

            if let line = decodeLine(data[lineStart..<index]), !body(line) { return }

            let separator = byte
            index = data.index(after: index)
            if separator == 0x0D, index < data.endIndex, data[index] == 0x0A {
                index = data.index(after: index)
            }
            lineStart = index
        }

        guard !Task.isCancelled else { return }
        if let line = decodeLine(data[lineStart..<data.endIndex]) {
            _ = body(line)
        }
    }

    /// Visits raw line bytes without decoding, so callers can run a cheap
    /// byte prefilter and decode only lines that may matter. Separators match
    /// ``forEachLine(in:_:)``: `\n`, `\r` and `\r\n`. The buffer is valid only
    /// for the duration of `body`. Returning `false`, or task cancellation,
    /// stops the walk.
    static func forEachLineBuffer(
        in data: Data,
        _ body: (UnsafeRawBufferPointer) -> Bool
    ) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let count = raw.count
            var lineStart = 0
            var index = 0
            while index < count {
                let byte = raw[index]
                guard byte == 0x0A || byte == 0x0D else {
                    index += 1
                    continue
                }
                if Task.isCancelled { return }
                if !body(UnsafeRawBufferPointer(rebasing: raw[lineStart..<index])) { return }
                index += 1
                if byte == 0x0D, index < count, raw[index] == 0x0A {
                    index += 1
                }
                lineStart = index
            }
            guard !Task.isCancelled else { return }
            _ = body(UnsafeRawBufferPointer(rebasing: raw[lineStart..<count]))
        }
    }

    /// Strict UTF-8 decode of one line buffer; nil for invalid bytes.
    static func decode(_ bytes: UnsafeRawBufferPointer) -> String? {
        String(bytes: bytes, encoding: .utf8)
    }

    private static func decodeLine(_ bytes: Data.SubSequence) -> String? {
        String(data: Data(bytes), encoding: .utf8)
    }
}

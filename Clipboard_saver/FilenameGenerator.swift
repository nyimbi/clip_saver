import Foundation

/// Derives a readable, filesystem-safe filename from the document body.
///
/// Prefers a Markdown heading because that is the one line the author meant as
/// a title. Falls back to the first non-empty line, then to a timestamp.
struct FilenameGenerator {

    private static let headingPattern = try! NSRegularExpression(
        pattern: #"^[ \t]{0,3}#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*$"#,
        options: []
    )

    /// `DateFormatter` is expensive to build; one per save is plenty.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    /// Long enough to stay useful, short enough to survive a path limit
    /// alongside a directory and a "(12)" collision suffix.
    static let maximumLength = 80

    /// The longest a single path component may be, in UTF-8 bytes, on APFS.
    /// Headroom is left for the ` (n)` collision suffix. This is the limit that
    /// applies to a name a person typed, which is never shortened for
    /// readability.
    static let byteLimit = 240

    /// macOS names that are reserved on a case-insensitive volume.
    static let reservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    // MARK: - Entry points

    static func make(from content: String, fileExtension: String, in directory: URL?) -> String {
        let stem = title(from: content).sanitizedForFilename
        let base = stem.isEmpty ? "clipboard_save_\(timestampFormatter.string(from: Date()))" : stem
        return resolveCollision("\(base).\(fileExtension)", in: directory)
    }

    /// The document's own title, or an empty string when there is none.
    static func title(from content: String) -> String {
        var previous: String?
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                previous = nil
                continue
            }
            // Setext heading: an `=` or `-` underline follows its text.
            if isSetextUnderline(line), let text = previous {
                return text
            }
            let range = NSRange(line.startIndex..., in: line)
            if let match = headingPattern.firstMatch(in: line, options: [], range: range),
               let valueRange = Range(match.range(at: 1), in: line) {
                return line[valueRange].trimmingCharacters(in: .whitespaces)
            }
            return line
        }
        return ""
    }

    // MARK: - Collision

    /// Appends ` (n)` until the name is free. Bounded so a pathological
    /// directory cannot spin forever.
    static func resolveCollision(_ base: String, in directory: URL?) -> String {
        guard let directory else { return base }
        let separator = base.lastIndex(of: ".") ?? base.endIndex
        let stem = String(base[..<separator])
        let suffix = String(base[separator...])

        var candidate = base
        var counter = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(stem) (\(counter))\(suffix)"
            counter += 1
            if counter > 9_999 { break }
        }
        return candidate
    }

    // MARK: - Helpers

    private static func isSetextUnderline(_ line: String) -> Bool {
        guard let first = line.first, first == "=" || first == "-" else { return false }
        return line.allSatisfy { $0 == first }
    }
}

extension String {
    /// Replaces characters that are illegal in a macOS filename, collapses
    /// whitespace, and truncates on a word boundary.
    var sanitizedForFilename: String {
        let cleaned = tidy()
        guard cleaned.count > FilenameGenerator.maximumLength else { return cleaned }
        // Prefer a word boundary so the name does not stop mid-word.
        let clipped = String(cleaned.prefix(FilenameGenerator.maximumLength))
        guard let boundary = clipped.lastIndex(of: " "), boundary > clipped.startIndex else {
            return clipped
        }
        return clipToByteLimit(String(clipped[..<boundary]))
    }

    /// Sanitises a name the user typed. Unlike `sanitizedForFilename` this
    /// does not impose the readability-oriented 80 character cut, because
    /// silently shortening something a person just typed is worse than a long
    /// filename. Only the file system's hard limit applies.
    var sanitizedForTypedFilename: String {
        clipToByteLimit(tidy())
    }

    private func tidy() -> String {
        var cleaned = replacingOccurrences(of: #"[/:*?"<>|\\]+"#, with: " ", options: .regularExpression)
        // Control characters and newlines become spaces rather than vanishing.
        cleaned = cleaned.unicodeScalars
            .map { $0.value < 0x20 ? " " : String($0) }
            .joined()
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Never end on a separator, and never repeat one: `Just a sentence.`
        // must not become `Just a sentence..txt`.
        let trailing = CharacterSet(charactersIn: " .,-_")
        while let last = cleaned.last, trailing.contains(String(last).unicodeScalars.first!) {
            cleaned.removeLast()
        }

        // A leading dot hides the file, and a bare reserved device name is
        // rejected outright by the file system.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if FilenameGenerator.reservedNames.contains(cleaned.uppercased()) {
            cleaned = "_\(cleaned)"
        }
        return cleaned
    }

    private func clipToByteLimit(_ name: String) -> String {
        guard name.utf8.count > FilenameGenerator.byteLimit else { return name }
        var result = ""
        for character in name {
            guard result.utf8.count + character.utf8.count <= FilenameGenerator.byteLimit else { break }
            result.append(character)
        }
        while let last = result.last,
              CharacterSet(charactersIn: " .,-_").contains(String(last).unicodeScalars.first!) {
            result.removeLast()
        }
        return result
    }
}

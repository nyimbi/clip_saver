import Foundation

/// Renders and reads the YAML frontmatter block.
///
/// The archive needs to read what it writes: dedup, search and incremental
/// save all need the title and platform without re-parsing the Markdown body,
/// and the body can be tens of thousands of lines. Round-tripping is
/// therefore a requirement, not a convenience — `render` output must always be
/// parseable by `parse`.
///
/// This is a deliberately small YAML subset: flat `key: value` pairs, with
/// quoting. Not a general YAML implementation, and it will not parse nested
/// structures written by something else.
enum Frontmatter {

    /// The ordered fields for a conversation, without the body hash.
    ///
    /// Split out from `block` construction so the renderer can append the hash
    /// of the body it is about to write. An untitled page with no source and
    /// one turn still gets a date and a turn count, so the list is never empty
    /// in practice.
    static func fields(for conversation: Conversation, now: Date = Date()) -> [(String, String)] {
        var fields: [(String, String)] = []

        let title = resolvedTitle(conversation)
        if !title.isEmpty { fields.append(("title", title)) }

        fields.append(("date", iso8601.day(from: now)))
        fields.append(("platform", conversation.source.displayName))
        fields.append(("turns", String(conversation.turns.count)))

        if let model = conversation.model, !model.isEmpty {
            fields.append(("model", model))
        }
        if let url = conversation.url {
            fields.append(("url", url.absoluteString))
        }
        if let strategy = conversation.confidence?.strategy, strategy != .none {
            fields.append(("extraction", strategy.rawValue))
        }

        // Incomplete extractions are recorded in the file, not just in the UI.
        // A file that says so is honest even if it is later separated from the
        // tool that wrote it.
        if let confidence = conversation.confidence, !confidence.complete {
            fields.append(("incomplete", "true"))
            for warning in confidence.warnings {
                fields.append(("warning", warning))
            }
        }

        return fields
    }

    /// Builds a block for a conversation, or `nil` when there is nothing worth
    /// recording.
    static func render(for conversation: Conversation, now: Date = Date()) -> String? {
        let fields = fields(for: conversation, now: now)
        return fields.isEmpty ? nil : block(fields)
    }

    /// The title, falling back to the first user turn when the page has none.
    ///
    /// Most chat UIs do expose a title, but a fresh conversation does not, and
    /// an untitled file is hard to find later.
    static func resolvedTitle(_ conversation: Conversation) -> String {
        if let title = conversation.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        guard let first = conversation.turns.first(where: { $0.role == .user }),
              let line = first.body.split(separator: "\n").first(where: { !$0.isEmpty })
        else { return "" }
        return String(line.prefix(120)).trimmingCharacters(in: .whitespaces)
    }

    static func block(_ fields: [(String, String)]) -> String {
        var out = "---\n"
        for (key, value) in fields {
            out += "\(key): \(quoteIfNeeded(value))\n"
        }
        out += "---\n"
        return out
    }

    /// Quotes when the value would otherwise be misread: leading/trailing
    /// space, YAML-significant leading characters, or a value that would parse
    /// as a number or boolean. A title of `2026` must stay a string.
    static func quoteIfNeeded(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }

        let needsQuotes =
            value != value.trimmingCharacters(in: .whitespaces)
            || ":#{}[],&*?|-<>=!%@`\"'\n\t".contains(value.first!)
            || value.contains(": ")
            || value.contains(" #")
            || value.contains("\n")
            || looksNumericOrBoolean(value)
        return needsQuotes ? "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" : value
    }

    private static func looksNumericOrBoolean(_ value: String) -> Bool {
        if ["true", "false", "null", "yes", "no", "on", "off", "~"].contains(value.lowercased()) {
            return true
        }
        return Double(value) != nil || Int(value) != nil
    }

    /// Parses a frontmatter block into key/value pairs.
    ///
    /// Returns `nil` when the text does not start with a frontmatter block at
    /// all, so a caller can tell "no frontmatter" from "empty frontmatter".
    ///
    /// Line-based rather than a search for `\n---`, because a block can be
    /// empty and `"---\n---\n"` has no closing fence preceded by a newline of
    /// its own.
    static func parse(_ text: String) -> [String: String]? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard let first = lines.first, first == "---" else { return nil }

        guard let closeIndex = lines.indices.dropFirst().first(where: {
            lines[$0] == "---" || lines[$0] == "..."
        }) else { return nil }

        var fields: [String: String] = [:]
        for line in lines[(lines.startIndex + 1)..<closeIndex] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            guard !key.isEmpty else { continue }
            // A repeated key (multiple `warning:` lines) accumulates rather than
            // overwriting, which is what makes the incomplete-extraction record
            // survive a round trip.
            if let existing = fields[key], !existing.isEmpty {
                fields[key] = existing + "\u{1}" + value
            } else {
                fields[key] = value
            }
        }
        return fields
    }

    /// All values for a key, for the fields that legitimately repeat.
    static func values(for key: String, in fields: [String: String]) -> [String] {
        guard let raw = fields[key] else { return [] }
        return raw.components(separatedBy: "\u{1}")
    }

    /// The text after any frontmatter block, with the block removed.
    ///
    /// Line-based to match `parse`, so the two always agree on where the body
    /// begins — including for an empty block, where a `\n---` search would fail.
    /// Blank lines between the closing fence and the first content line are
    /// consumed, so the result is the document body proper rather than a run of
    /// leading newlines the caller would otherwise have to strip itself.
    static func stripping(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard let first = lines.first, first == "---" else { return text }
        guard let closeIndex = lines.indices.dropFirst().first(where: {
            lines[$0] == "---" || lines[$0] == "..."
        }) else { return text }

        var body = Array(lines[(closeIndex + 1)...])
        while let first = body.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            body.removeFirst()
        }
        return body.joined(separator: "\n")
    }
}

enum iso8601 {
    static func day(from date: Date) -> String {
        formatter(for: "yyyy-MM-dd").string(from: date)
    }

    static func timestamp(from date: Date) -> String {
        formatter(for: "yyyy-MM-dd'T'HH:mm:ssZ").string(from: date)
    }

    private static func formatter(for format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }
}

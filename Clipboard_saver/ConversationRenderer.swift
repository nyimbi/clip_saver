import Foundation

/// Renders a conversation as a Markdown document.
///
/// Every saved archive file is produced here, so the two entry points —
/// `render` for a new file and `renderIncremental` for a re-save — must agree
/// on the per-turn representation. They share `renderTurn` for exactly that
/// reason: if the two formats drifted, a re-saved file would not be
/// byte-comparable to the original and the merge logic could not find its own
/// output.
enum ConversationRenderer {

    /// The block used to carry reasoning, which the reader must be able to find
    /// again. Markers are kept as constants so the writer and the reader cannot
    /// drift apart.
    static let reasoningOpen = "<details>\n<summary>Reasoning</summary>"
    static let reasoningClose = "</details>"

    /// The block used to carry a tool call.
    static let toolFence = "```json"

    /// The body of a turn, in the format both writers use.
    ///
    /// `## User` / `## Assistant` rather than a role prefix, because these files
    /// get read by people as well as tools and a heading is navigable in every
    /// Markdown viewer, while a bolded prefix is not.
    ///
    /// Parts are joined with a blank line rather than concatenated, so every
    /// section is separated the same way regardless of which ones are present.
    /// That is also what makes the format invertible: `decodeTurn` splits on
    /// blank-line-separated sections and the reconstruction is exact.
    ///
    /// A turn with no body, no reasoning and no tool calls renders to nothing.
    /// Chat UIs emit those constantly — a cancelled generation, an empty
    /// assistant bubble — and a bare `## Assistant` heading with nothing under it
    /// is noise in a file meant to be read.
    static func renderTurn(_ turn: Turn) -> String {
        var parts: [String] = [heading(for: turn.role)]

        if let reasoning = turn.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reasoning.isEmpty {
            parts.append(reasoningOpen + "\n\n" + reasoning + "\n\n" + reasoningClose)
        }

        for call in turn.toolCalls {
            parts.append(renderToolCall(call))
        }

        if !turn.attachments.isEmpty {
            parts.append(renderAttachments(turn.attachments))
        }

        // An HTML body is converted here rather than in the browser, so the
        // structural converter stays in one place with its 64 tests behind it.
        // A conversion that fails leaves the raw HTML visible rather than an
        // empty turn, which would read as a message with no content.
        let body: String
        switch turn.format {
        case .markdown:
            body = turn.body.trimmingCharacters(in: .whitespacesAndNewlines)
        case .html:
            body = (HTMLToMarkdown.convert(turn.body) ?? turn.body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !body.isEmpty {
            parts.append(body)
        }

        // Heading alone means there was nothing else to say.
        return parts.count == 1 ? "" : parts.joined(separator: "\n\n")
    }

    /// Attachments as a list of references.
    ///
    /// A list rather than inline images, deliberately. Downloading is not this
    /// tool's job and never will be, so a link that promises a file and then
    /// 404s is worse than an honest reference: the name, the kind and the size
    /// survive, and the note says plainly that the bytes are elsewhere.
    static func renderAttachments(_ attachments: [Attachment]) -> String {
        var lines = ["**Attachments**", ""]
        for attachment in attachments {
            var line = "- \(attachment.codeSpan) (\(attachment.kind))"
            // Exact bytes, not "12.4 KB".
            //
            // A human-readable size cannot survive a round trip: 12400 bytes
            // renders as "12 KB" and reads back as 12000, so the file would
            // differ from what we wrote and every re-save would look like a
            // hand edit. ByteCountFormatter is for the label on screen, not for
            // the persistence layer. 12400 is no less readable and it is exact.
            if let size = attachment.byteSize {
                line += " — \(size) bytes"
            }
            if attachment.inline {
                line += " — inline in the page"
            } else if let url = attachment.url, !url.isEmpty {
                line += " — \(url)"
            } else {
                line += " — not downloadable from the page"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Inverts `renderTurn`.
    ///
    /// Without this the reasoning and tool-call decoration would be absorbed into
    /// the message body on re-read, the body hash would never match, and every
    /// re-save of a conversation containing reasoning would be treated as a
    /// hand-edited file.
    /// Recognises the attachment block so a re-read does not absorb it into the
    /// message body -- which would make the body hash mismatch and every re-save
    /// look like a hand-edited file.
    static let attachmentHeading = "**Attachments**"

    static func decodeTurn(_ role: TurnRole, _ text: String) -> Turn {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var reasoning: String?
        var toolCalls: [ToolCall] = []

        if let open = remaining.range(of: reasoningOpen + "\n\n"),
           let close = remaining.range(of: "\n\n" + reasoningClose, range: open.upperBound..<remaining.endIndex) {
            reasoning = String(remaining[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            remaining = String(remaining[close.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Tool fences are written contiguously at the head of a turn, so only a
        // *leading* fence is decoration. Scanning the whole body for fences would
        // swallow a JSON block the assistant itself wrote, which is a common
        // thing for it to write.
        while remaining.hasPrefix(toolFence + "\n") {
            let payloadStart = remaining.index(remaining.startIndex, offsetBy: toolFence.count + 1)
            guard let fenceEnd = remaining.range(of: "\n```", range: payloadStart..<remaining.endIndex) else {
                break
            }
            if let call = decodeToolCall(String(remaining[payloadStart..<fenceEnd.lowerBound])) {
                toolCalls.append(call)
            }
            remaining = String(remaining[fenceEnd.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // The attachment block is lifted out of the body. Re-reading it as prose
        // would change the body, and a changed body means a changed hash, and a
        // changed hash means every re-save of a conversation with attachments is
        // treated as a hand edit.
        //
        // The block is a paragraph: heading, blank line, one line per file. So
        // its extent runs to the next blank line. Removing only the *prefix*
        // would take the whole turn with it, because the block sits before the
        // body in the rendered order.
        var attachments: [Attachment] = []
        if let headingRange = remaining.range(of: attachmentHeading),
           let blockEnd = endOfAttachmentBlock(in: remaining, from: headingRange.lowerBound) {
            attachments = parseAttachments(String(remaining[headingRange.lowerBound..<blockEnd]))
            // The text before the block, plus the text after it. Dropping only
            // the prefix would take the turn with it, because the block sits
            // before the body in the rendered order.
            remaining = String(remaining[..<headingRange.lowerBound]) + String(remaining[blockEnd...])
        }

        let body = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return Turn(
            role: role,
            body: body,
            reasoning: reasoning,
            toolCalls: toolCalls,
            attachments: attachments
        )
    }

    /// Reads back the reference lines this renderer wrote.
    ///
    /// Deliberately marker-driven rather than clever: the renderer and the
    /// parser are the same file and change together, so the only thing worth
    /// optimising for is that neither of them has to guess.
    static func parseAttachments(_ block: String) -> [Attachment] {
        var found: [Attachment] = []
        for line in block.split(separator: "\n") {
            guard line.hasPrefix("- `") else { continue }

            // Read the fence, then the name up to a run of the same length. A
            // name containing backticks is why the fence is variable, so the
            // width has to be measured rather than assumed to be one.
            //
            // "- " is two characters; the fence starts at the third.
            let afterOpen = line.index(line.startIndex, offsetBy: 2)
            var width = 0
            var scan = afterOpen
            while scan < line.endIndex, line[scan] == "`" {
                width += 1
                scan = line.index(after: scan)
            }
            guard width > 0 else { continue }

            // The name runs to the *start* of the next run of `width` backticks,
            // not its end, so the closing fence is not read as part of the name.
            var runStart: String.Index?
            var run = 0
            var close = scan
            while close < line.endIndex {
                if line[close] == "`" {
                    if run == 0 { runStart = close }
                    run += 1
                    if run == width { break }
                } else {
                    run = 0
                }
                close = line.index(after: close)
            }
            guard let fenceStart = runStart, close < line.endIndex else { continue }

            // CommonMark strips one space of padding when both ends have it.
            var name = String(line[scan..<fenceStart])
            if name.hasPrefix(" ") && name.hasSuffix(" "), name.count > 1 {
                name = String(name.dropFirst().dropLast())
            }
            guard !name.isEmpty else { continue }
            let afterFence = line.index(close, offsetBy: width, limitedBy: line.endIndex) ?? line.endIndex
            let rest = String(line[afterFence...])

            // "(image)" -- written on every line.
            var kind: String?
            if let open = rest.range(of: "(") {
                let tail = rest[rest.index(after: open.lowerBound)...]
                let value = String(tail.prefix { $0 != ")" })
                if !value.isEmpty { kind = value }
            }

            // "12400 bytes" -- exact, so it reads back exactly.
            var size: Int?
            if let match = rest.range(of: #"\d+ bytes"#, options: String.CompareOptions.regularExpression) {
                size = Int(rest[match].prefix(while: { $0.isNumber }))
            }

            // The url is the trailing token, and only ever an http(s) one, so a
            // filename containing a bracket cannot be mistaken for one.
            var url: String?
            if let match = rest.range(of: #"https?://\S+"#, options: String.CompareOptions.regularExpression) {
                url = String(rest[match])
            }

            let inline = rest.contains("inline in the page")
            found.append(Attachment(
                name: name,
                kind: kind,
                byteSize: size,
                url: url,
                inline: inline
            ))
        }
        return found
    }

    /// Where the attachment block ends.
    ///
    /// The block is a paragraph: a heading, a blank line, one line per file, and
    /// a blank line before whatever follows. Scanning to the next blank line is
    /// enough to find it, and it fails safe -- a heading with no list after it
    /// yields a one-paragraph block and no attachments rather than eating the
    /// rest of the turn.
    static func endOfAttachmentBlock(in text: String, from start: String.Index) -> String.Index? {
        // Step past the heading line itself.
        var cursor = start
        while cursor < text.endIndex, text[cursor] != "\n" {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return nil }
        cursor = text.index(after: cursor)

        // The blank line between the heading and the list.
        while cursor < text.endIndex, text[cursor] == "\n" {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return nil }

        // The list, up to the next blank line or the end of the turn.
        var end = start
        var lineStart = cursor
        while lineStart < text.endIndex {
            var lineEnd = lineStart
            while lineEnd < text.endIndex, text[lineEnd] != "\n" {
                lineEnd = text.index(after: lineEnd)
            }
            if text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces).isEmpty { break }
            end = lineEnd
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
        }
        return end > start ? end : nil
    }

    private static func decodeToolCall(_ payload: String) -> ToolCall? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["tool"] as? String
        else { return nil }
        return ToolCall(
            name: name,
            input: object["input"] as? String,
            output: object["output"] as? String
        )
    }

    static func heading(for role: TurnRole) -> String {
        switch role {
        case .user: return "## User"
        case .assistant: return "## Assistant"
        case .reasoning: return "## Reasoning"
        }
    }

    /// Tool calls as fenced JSON, which is parseable and does not need its own
    /// Markdown extension. `sortedKeys` keeps the output stable, because the
    /// body hash covers it.
    static func renderToolCall(_ call: ToolCall) -> String {
        var payload: [String: String] = ["tool": call.name]
        if let input = call.input, !input.isEmpty { payload["input"] = input }
        if let output = call.output, !output.isEmpty { payload["output"] = output }

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
        ), let json = String(data: data, encoding: .utf8) else {
            return "```\n\(call.name)\n```"
        }
        return toolFence + "\n" + json + "\n```"
    }

    /// A complete document: frontmatter, title heading, then the turns.
    ///
    /// The body hash is appended to the frontmatter *after* rendering the turns,
    /// so it covers the exact text that was written.
    static func render(_ conversation: Conversation, now: Date = Date()) -> String {
        var frontmatterFields = Frontmatter.fields(for: conversation, now: now)
        let body = renderTurns(conversation.turns)
        frontmatterFields.append((bodyHashKey, bodyHash(turns: conversation.turns)))
        // The saver's own content identity, so a re-save recognises this file
        // and the archive can find the same conversation saved under two names.
        frontmatterFields.append((fingerprintKey, Fingerprint.short(conversation, length: 16)))

        var out = Frontmatter.block(frontmatterFields)
        out += "\n"

        let title = Frontmatter.resolvedTitle(conversation)
        if !title.isEmpty {
            out += "# \(title)\n\n"
        }
        out += body

        // A partial extraction says so in the body, not only in the frontmatter.
        // Frontmatter is metadata that tools read and people skip; this is the
        // part a human opening the file will actually see.
        if let confidence = conversation.confidence, !confidence.complete {
            out += "\n---\n\n"
            out += "> **This capture is incomplete.** "
            out += warningSentence(confidence)
            out += "\n"
        }

        return out
    }

    static func warningSentence(_ confidence: ExtractionConfidence) -> String {
        if !confidence.warnings.isEmpty {
            return confidence.warnings.joined(separator: "; ") + "."
        }
        if confidence.score < ExtractionConfidence.reliable {
            return "The page had not finished loading all messages when this was saved (confidence "
                + String(format: "%.2f", confidence.score) + ")."
        }
        return "Not every message was captured."
    }

    /// Turns only, separated by blank lines. Shared by both writers.
    ///
    /// A turn whose body is empty *and* which carries no reasoning or tool calls
    /// renders to nothing at all. Chat UIs emit those constantly — a cancelled
    /// generation, an empty assistant bubble — and a bare `## Assistant`
    /// heading with nothing under it is noise in a file meant to be read.
    static func renderTurns(_ turns: [Turn]) -> String {
        turns
            .map { renderTurn($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// The frontmatter key holding the hash of the rendered turn body.
    static let bodyHashKey = "body-hash"

    /// The frontmatter key holding the saver's own content fingerprint.
    ///
    /// Written by the saver so a re-save recognises its output. The archive
    /// never invents one for a file it did not write — see `ArchiveIndexer`.
    static let fingerprintKey = "fingerprint"

    /// Hash of the turn section, used to prove a file on disk is still exactly
    /// what this renderer produced.
    static func bodyHash(turns: [Turn]) -> String {
        Fingerprint.digest(Conversation(title: nil, source: .webPage, turns: turns))
    }

    /// The outcome of reading a document back.
    ///
    /// `isIntact` is the important field. A body that happens to contain the
    /// literal text `## Assistant` is genuinely indistinguishable from a turn
    /// boundary, and no escaping scheme fixes that without corrupting the
    /// user's text. So rather than trying to be clever, the renderer records a
    /// hash of what it wrote and the reader verifies its reconstruction against
    /// it. A parse that cannot reproduce the recorded hash has been changed by
    /// hand, and the caller takes the non-destructive path instead of guessing.
    struct ParsedDocument {
        var turns: [Turn]
        var isIntact: Bool
        /// From the file's own frontmatter. Needed to recompute a fingerprint
        /// comparable to an incoming conversation's — a file read back from
        /// disk is frontmatter plus turns, not a `Conversation`.
        var source: ConversationSource
        var model: String?
    }

    /// Recovers turns from a document this renderer wrote.
    static func parse(from document: String) -> ParsedDocument {
        let fields = Frontmatter.parse(document)
        let body = Frontmatter.stripping(document)
        let turns = splitTurns(from: body)
        let recorded = fields?[bodyHashKey]
        let source = ConversationSource(identifier: fields?["platform"] ?? "")
        let model = fields?["model"]

        // A file with no recorded hash predates this field, or was written by
        // another tool. Its turns are still parsed, but not trusted.
        guard let recorded, !recorded.isEmpty else {
            return ParsedDocument(turns: turns, isIntact: false, source: source, model: model)
        }
        return ParsedDocument(
            turns: turns,
            isIntact: recorded == bodyHash(turns: turns),
            source: source,
            model: model
        )
    }

    /// Convenience for callers that do not care about verification. Only use
    /// where a wrong answer is harmless.
    static func parseTurns(from document: String) -> [Turn] {
        splitTurns(from: Frontmatter.stripping(document))
    }

    private static func splitTurns(from body: String) -> [Turn] {
        var turns: [Turn] = []
        var current: TurnRole?
        var buffer: [String] = []

        func flush() {
            guard let role = current else { return }
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                turns.append(decodeTurn(role, text))
            }
            current = nil
            buffer = []
        }

        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if let role = role(forHeading: String(line)) {
                flush()
                current = role
                continue
            }
            if current != nil {
                buffer.append(String(line))
            }
        }
        flush()
        return turns
    }

    static func role(forHeading line: String) -> TurnRole? {
        switch line.trimmingCharacters(in: .whitespaces) {
        case "## User": return .user
        case "## Assistant": return .assistant
        case "## Reasoning": return .reasoning
        default: return nil
        }
    }
}

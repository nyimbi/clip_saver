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

        let body = turn.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            parts.append(body)
        }

        // Heading alone means there was nothing else to say.
        return parts.count == 1 ? "" : parts.joined(separator: "\n\n")
    }

    /// Inverts `renderTurn`.
    ///
    /// Without this the reasoning and tool-call decoration would be absorbed into
    /// the message body on re-read, the body hash would never match, and every
    /// re-save of a conversation containing reasoning would be treated as a
    /// hand-edited file.
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

        let body = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return Turn(role: role, body: body, reasoning: reasoning, toolCalls: toolCalls)
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
    }

    /// Recovers turns from a document this renderer wrote.
    static func parse(from document: String) -> ParsedDocument {
        let fields = Frontmatter.parse(document)
        let body = Frontmatter.stripping(document)
        let turns = splitTurns(from: body)
        let recorded = fields?[bodyHashKey]

        // A file with no recorded hash predates this field, or was written by
        // another tool. Its turns are still parsed, but not trusted.
        guard let recorded, !recorded.isEmpty else {
            return ParsedDocument(turns: turns, isIntact: false)
        }
        return ParsedDocument(turns: turns, isIntact: recorded == bodyHash(turns: turns))
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

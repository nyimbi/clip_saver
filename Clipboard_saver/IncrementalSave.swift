import Foundation

/// What a re-save should do to a file that already exists.
///
/// The point of this type is that the decision is a value, not a side effect.
/// The destructive cases are enumerable, so a test can assert exactly which one
/// a given pair of old and new conversations produces, and the writer becomes
/// a switch that cannot surprise anyone.
enum SaveAction: Equatable {
    /// No file at that path, or the existing one is not one of ours.
    case writeNew
    /// Byte-identical content already on disk.
    case unchanged
    /// The new conversation is a strict prefix-extension of the old one.
    case append(turns: [Turn])
    /// Same turns, but details changed (title, model, frontmatter).
    case rewrite
    /// The two have diverged — the user edited the file, or the thread was
    /// regenerated. Never destructive.
    case writeAlongside

    /// Whether the existing file may be rewritten.
    var isDestructive: Bool {
        switch self {
        case .append, .rewrite: return true
        case .writeNew, .unchanged, .writeAlongside: return false
        }
    }
}

/// Decides what a re-save does.
///
/// This is the highest-risk code in the archive: it overwrites files a person
/// may have edited by hand, and those files are the only copy of a
/// conversation that exists. The rules that follow from that:
///
///   1. Never destroy content. A divergence writes a new file rather than
///      clobbering, so a mistake costs a stray file, not a conversation.
///   2. Never trust a file the tool cannot prove it wrote. The renderer records
///      a hash of the body; a mismatch means a human edited it, and a human's
///      edits outrank a machine's idea of the content.
///   3. Only ever append. A re-save can add turns, never remove them, so a
///      thread that lost a message in the browser does not lose it on disk.
enum IncrementalSave {

    /// Classifies a re-save without touching the file system.
    ///
    /// - Parameters:
    ///   - existing: the text already on disk, or `nil` if there is no file.
    ///   - incoming: the conversation just extracted.
    static func decide(existing: String?, incoming: Conversation) -> SaveAction {
        guard let existing, !existing.isEmpty else { return .writeNew }
        guard Frontmatter.parse(existing) != nil else {
            // A Markdown file this tool did not write. Its content is someone
            // else's; leave it alone.
            return .writeAlongside
        }

        let parsed = ConversationRenderer.parse(from: existing)
        guard parsed.isIntact else {
            // The body no longer matches the hash recorded when it was written,
            // so it has been edited by hand. A role heading inside a body can
            // also break reconstruction, and the hash is what detects that. Both
            // cases end the same way: do not touch it.
            return .writeAlongside
        }

        let oldTurns = parsed.turns
        let newTurns = incoming.turns

        if oldTurns.isEmpty && newTurns.isEmpty { return .unchanged }

        // Identical content: the common case when the user re-saves without
        // adding anything, and the one that must not touch the mtime.
        if Fingerprint.normalise(ConversationRenderer.renderTurns(oldTurns))
            == Fingerprint.normalise(ConversationRenderer.renderTurns(newTurns)) {
            return .unchanged
        }

        // Strict prefix-extension. Compared on normalised content, so
        // whitespace differences from a different extraction strategy do not
        // read as divergence.
        guard newTurns.count > oldTurns.count else { return .writeAlongside }
        let prefix = newTurns.prefix(oldTurns.count)
        let prefixMatches = zip(prefix, oldTurns).allSatisfy { normalised($0) == normalised($1) }
        guard prefixMatches else { return .writeAlongside }

        let addition = Array(newTurns.dropFirst(oldTurns.count))
        return addition.isEmpty ? .unchanged : .append(turns: addition)
    }

    private static func normalised(_ turn: Turn) -> String {
        Fingerprint.normalise(turn.role.rawValue + "\u{1}" + turn.body)
    }

    /// Applies an action, returning the text to write.
    ///
    /// - Returns: `nil` when nothing should be written, which is the signal for
    ///   the caller to leave the file alone entirely.
    static func apply(_ action: SaveAction, incoming: Conversation, existing: String?, now: Date = Date()) -> String? {
        switch action {
        case .writeNew, .rewrite, .writeAlongside:
            return ConversationRenderer.render(incoming, now: now)
        case .unchanged:
            return nil
        case .append:
            // Re-render the whole document rather than splicing text onto the
            // end. The frontmatter carries the turn count and the completeness
            // flag, both of which just changed, and appending a body without
            // updating the header is how the two drift apart. The old turns are
            // byte-identical to the new prefix — `decide` proved that — so
            // rebuilding loses nothing.
            return ConversationRenderer.render(incoming, now: now)
        }
    }
}

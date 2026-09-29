import Foundation

/// Merges a conversation into a daily note.
///
/// The interesting problem here is that a daily note is *not* a file this tool
/// wrote. It has the user's own prose in it, no frontmatter, and no body hash,
/// so `IncrementalSave` would classify it as foreign and decline to touch it —
/// which is correct behaviour for an arbitrary file and useless here.
///
/// So the daily note is handled by a different mechanism entirely: a delimited
/// section with a marker, and a fingerprint inside it. That gives:
///
///   - **Append** — a conversation not already in the note is added.
///   - **Idempotence** — re-saving the same conversation replaces its own
///     section rather than appending a second copy, so pressing save five times
///     leaves one entry.
///   - **Update** — a grown conversation replaces its section with the longer
///     version.
///   - **Non-destructiveness** — everything outside a marked section is the
///     user's and is never rewritten, reordered or reformatted. If the markers
///     are missing or the note is not text, nothing is written at all.
enum DailyNote {

    /// The marker is an HTML comment, which no Markdown renderer shows and no
    /// writing tool strips.
    ///
    /// It carries the fingerprint so a section can be found again without
    /// re-hashing the whole note.
    static func marker(for fingerprint: String) -> String {
        "<!-- clipboard-saver:\(fingerprint) -->"
    }

    /// The end of a section.
    ///
    /// Without an explicit end, a section's extent is "until the next marker or
    /// the end of the file" -- so replacing the last section in a note also
    /// rewrites whatever the user wrote after it. That is the one failure this
    /// mechanism cannot recover from, because the user's text is gone and this
    /// tool is the only thing that had it. Both markers are emitted on every
    /// write, and a section lacking an end marker is treated as un-editable.
    static let endMarker = "<!-- /clipboard-saver -->"

    /// What adding a conversation to a daily note would do.
    enum Action: Equatable {
        /// The note is new, or has no conversation from this one.
        case insert
        /// The conversation is already in the note, unchanged.
        case unchanged
        /// The conversation is already in the note but has grown.
        case replace
        /// The note is not something this can safely edit.
        case refuse(String)
    }


    /// Where a conversation's section sits in a note.
    struct SectionRange {
        /// From the opening marker to just past the end marker.
        var whole: Range<String.Index>
        /// The section's text, delimiters included.
        var text: String
        /// The section's content: everything between the heading and the end
        /// marker, which is the part that carries meaning.
        var content: String
    }

    /// Locates a conversation's section, or `nil` when it is not there.
    ///
    /// A section with no end marker is reported as absent rather than assumed to
    /// run to the end of the file, because that assumption is what destroys the
    /// text after it.
    static func locateSection(in note: String, for conversation: Conversation) -> SectionRange? {
        let fingerprint = Fingerprint.short(conversation, length: 16)
        guard let open = note.range(of: marker(for: fingerprint)) else { return nil }

        // The end marker must be the *first* one after this section's opening
        // marker. Searching from after the whole section instead would find the
        // next section's end marker, and the replacement would then swallow the
        // conversation in between.
        let searchStart = open.upperBound
        guard let close = note.range(of: endMarker, range: searchStart..<note.endIndex),
              close.lowerBound >= searchStart
        else { return nil }

        let whole = open.lowerBound..<close.upperBound
        let text = String(note[whole])
        return SectionRange(whole: whole, text: text, content: Self.normalise(text))
    }

    /// A section's text with surrounding whitespace removed.
    ///
    /// The trailing newline is the only difference between a section as written
    /// and the same section as read back, and comparing them without
    /// normalising made every save a "replace" -- so a daily note was rewritten
    /// every time, which is both wasteful and a stream of pointless file changes
    /// for anything watching the folder.
    static func normalise(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text of a conversation's section, or `nil` when it is not present.
    static func existingSection(in note: String, for conversation: Conversation) -> String? {
        locateSection(in: note, for: conversation)?.text
    }

    /// Decides what adding `conversation` to `note` would do.
    ///
    /// Compares the section's *content*, not the whole section. The section
    /// carries a timestamp, and a section rebuilt now never matches one written
    /// a moment ago — so comparing whole sections made `.unchanged` unreachable
    /// and rewrote the daily note on every single save.
    ///
    /// The timestamp is metadata, not content, and it is deliberately not part
    /// of the comparison: it records when the conversation was first saved, and
    /// re-stamping it on every save would make the note a record of when you
    /// pressed the button rather than of when you had the conversation.
    /// A section reduced to what identifies its content: the opening marker, the
    /// heading, the turns, and the closing marker, with the timestamp line and
    /// surrounding whitespace removed.
    ///
    /// The timestamp has to be excluded on *both* sides of the comparison. It is
    /// the only part of a section that legitimately differs between two saves of
    /// the same conversation, and comparing a section that has one against a
    /// normalised section that does not can never match — which is what made
    /// every save a "replace".
    static func comparable(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix("<sub>") }
        return normalise(lines.joined(separator: "\n"))
    }

    static func decide(note: String, conversation: Conversation, now: Date = Date()) -> Action {
        if let located = locateSection(in: note, for: conversation) {
            return comparable(makeSection(conversation, now: now)) == comparable(located.text)
                ? .unchanged
                : .replace
        }

        // A grown thread. Its fingerprint has moved on, because the fingerprint
        // covers the content, so the marker can no longer reach the section it
        // belongs to -- and the section is added a second time instead of
        // updated. The same conversation then appears twice in one day, which is
        // the bloat the archive exists to prevent, and it contradicts what the
        // separate destination does with the same input.
        //
        // The heading is the handle that survives growth, so it finds the section
        // the fingerprint cannot.
        if let section = locateSection(in: note, heading: bodyHeading(for: conversation)) {
            // Replace only when the existing section is a strict prefix of what
            // is in hand. If the two have genuinely diverged the section is left
            // alone and a new one added, because replacing would lose whichever
            // version is not currently loaded.
            return isExtension(of: section, by: conversation) ? .replace : .insert
        }

        return .insert
    }

    /// Locates a section by its heading, for a conversation whose fingerprint has
    /// moved on.
    static func locateSection(in note: String, heading: String) -> SectionRange? {
        guard let headingRange = note.range(of: heading) else { return nil }
        guard let open = note.range(
            of: "<!-- clipboard-saver:",
            options: .backwards,
            range: note.startIndex..<headingRange.lowerBound
        ) else { return nil }
        guard let close = note.range(of: endMarker, range: headingRange.upperBound..<note.endIndex) else {
            return nil
        }
        let whole = open.lowerBound..<close.upperBound
        let text = String(note[whole])
        return SectionRange(whole: whole, text: text, content: normalise(text))
    }

    /// Whether an existing section is an earlier state of this conversation: a
    /// strict prefix, in order, unchanged.
    ///
    /// The delimiters are stripped before parsing. `parseTurns` reads to the end
    /// of its input, so an end marker left in place becomes part of the last
    /// turn's body — the comparison then fails on the marker rather than on the
    /// content, and every grown conversation looks diverged.
    static func isExtension(of section: SectionRange, by conversation: Conversation) -> Bool {
        let body = section.text
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("<!--") }
            .joined(separator: "\n")
        let existing = ConversationRenderer.parseTurns(from: body)
        guard !existing.isEmpty, existing.count <= conversation.turns.count else { return false }
        return zip(existing, conversation.turns).allSatisfy { old, new in
            old.role == new.role && Fingerprint.normalise(old.body) == Fingerprint.normalise(new.body)
        }
    }

    /// The heading a section carries: the handle that survives growth.
    static func bodyHeading(for conversation: Conversation) -> String {
        "### \(Frontmatter.resolvedTitle(conversation))"
    }

    /// Applies the decision, returning the new note contents.
    static func apply(
        _ action: Action,
        note: String,
        conversation: Conversation,
        now: Date = Date()
    ) -> String? {
        switch action {
        case .unchanged, .refuse:
            return nil

        case .insert:
            return appending(makeSection(conversation, now: now), to: note, now: now)

        case .replace:
            // Replaced in place rather than appended, so a grown thread updates
            // where the reader expects to find it instead of moving to the end
            // of the day. The section is found by fingerprint or by heading,
            // because a grown conversation's fingerprint no longer matches.
            let section = makeSection(conversation, now: now)
            if locateSection(in: note, for: conversation) != nil {
                return replacingSection(in: note, for: conversation, with: section)
            }
            return replacingSection(in: note, heading: bodyHeading(for: conversation), with: section) ?? appending(section, to: note, now: now)
        }
    }

    // MARK: - Sections

    static func makeSection(_ conversation: Conversation, now: Date = Date()) -> String {
        let fingerprint = Fingerprint.short(conversation, length: 16)
        var out = marker(for: fingerprint) + "\n\n"
        out += "### \(Frontmatter.resolvedTitle(conversation))\n\n"
        if let url = conversation.url {
            out += "<sub>\(iso8601.timestamp(from: now)) · [source](\(url.absoluteString))</sub>\n\n"
        }
        out += ConversationRenderer.renderTurns(conversation.turns) + "\n"
        out += endMarker + "\n"
        return out
    }

    /// Appends a section, under a day heading if the note has none.
    static func appending(_ section: String, to note: String, now: Date = Date()) -> String {
        var out = note
        // A leading blank line so the section is not glued to whatever the
        // user's last line was.
        if !out.isEmpty {
            if !out.hasSuffix("\n\n") {
                out += out.hasSuffix("\n") ? "\n" : "\n\n"
            }
        } else {
            out = "# \(iso8601.day(from: now))\n\n"
        }
        out += section
        return out
    }

    /// Replaces one conversation's section, leaving everything else alone.
    ///
    /// Bounded by the end marker rather than by the next section, so text the
    /// user wrote after the last section is never touched. A section with no end
    /// marker is left exactly as it is: its extent is unknown, and guessing
    /// wrong here loses the user's own writing.
    static func replacingSection(in note: String, for conversation: Conversation, with section: String) -> String {
        guard let located = locateSection(in: note, for: conversation) else { return note }
        return String(note[..<located.whole.lowerBound]) + section + String(note[located.whole.upperBound...])
    }

    static func replacingSection(in note: String, heading: String, with section: String) -> String? {
        guard let located = locateSection(in: note, heading: heading) else { return nil }
        return String(note[..<located.whole.lowerBound]) + section + String(note[located.whole.upperBound...])
    }

    /// Removes a conversation's section. Exposed so a test can assert that
    /// nothing outside the markers is disturbed.
    static func stripAllSections(_ note: String, of conversation: Conversation) -> String? {
        guard locateSection(in: note, for: conversation) != nil else { return nil }
        return replacingSection(in: note, for: conversation, with: "")
    }

}

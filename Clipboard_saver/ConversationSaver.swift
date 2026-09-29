import Foundation

/// Writes an extracted conversation to disk.
///
/// The trust boundary sits here. The extension is a separate process and names
/// its own destination, so every path it supplies is resolved and checked
/// before a byte is written. A buggy or compromised extension must not be able
/// to name an arbitrary location.
struct ConversationSaver {

    enum Failure: Error {
        case noDestination
        case unwritable(String)
        case cancelled

        var asBridgeFailure: BridgeResponse.Failure {
            switch self {
            case .noDestination:
                return .init(
                    code: .noDestination,
                    message: "No folder to save into. Set one in the app's settings.",
                    recoverable: true
                )
            case .unwritable(let path):
                return .init(
                    code: .unwritableDestination,
                    message: "Could not write to \(path). Check that it exists and is writable.",
                    recoverable: true
                )
            case .cancelled:
                return .init(code: .internalError, message: "Save cancelled.", recoverable: true)
            }
        }
    }

    /// What happened, in terms the caller can report to a person.
    struct Result {
        var path: String?
        var action: String
        var turns: Int
        var confidence: Double
        var complete: Bool
        var incompleteReason: String?
    }

    /// Asks for a filename. `nil` when the user cancels.
    var requestFilename: (_ suggested: String, _ directory: URL) -> String?

    init(requestFilename: @escaping (String, URL) -> String? = { _, _ in nil }) {
        self.requestFilename = requestFilename
    }

    func save(
        _ conversation: Conversation,
        destination: String?,
        behaviour: BridgeRequest.Behaviour
    ) throws -> Result {
        let directory = try resolveDirectory(destination)
        let existing = existingFile(for: conversation, in: directory)
        // A hand-edited file stops matching, because the edit is precisely what
        // the comparison looks at. So the decline has to be recorded here rather
        // than discovered later: the file is found, recognised as not-updatable,
        // and the save is reported as the deliberate `writeAlongside` it is.
        // Falling through to `writeNew` instead would tell the user their thread
        // was saved while quietly making a duplicate of a file they had edited.
        let action = IncrementalSave.decide(existing: existing?.text, incoming: conversation)
        let document = IncrementalSave.apply(action, incoming: conversation, existing: existing?.text)
            ?? ConversationRenderer.render(conversation)

        // The conversation's own title, not the rendered document. Deriving a
        // name from the document means asking the filename generator to find the
        // first heading, and the document's first heading is the title anyway —
        // but an untitled conversation then falls through to the date-based
        // default, and a platform that hid its heading yields a name like
        // `clipboard_save_2026-09-29`. The title is the fact we have.
        // Name the file the conversation already has, when there is one.
        //
        // Deriving a name from the title and letting `FilenameGenerator` resolve
        // the collision looks equivalent, and is not: on an `unchanged` re-save
        // the document is not rewritten, so no file exists at the resolved
        // path, and the *next* save then finds a collision and picks "Thread
        // (1).md" — a different filename, therefore a different fingerprint,
        // therefore a brand new conversation. Three files from one thread. The
        // existing file's own name is the only name guaranteed to be stable.
        let title = Frontmatter.resolvedTitle(conversation)
        let suggested: String
        if let existing, action != .writeAlongside {
            suggested = existing.url.lastPathComponent
        } else {
            suggested = FilenameGenerator.make(
                from: title.isEmpty ? conversation.turns.first?.body ?? "Chat" : title,
                fileExtension: "md",
                in: directory
            )
        }

        let name: String
        switch behaviour {
        case .auto:
            name = suggested
        case .ask:
            guard let chosen = requestFilename(suggested, directory) else { throw Failure.cancelled }
            name = chosen
        }

        // `writeAlongside` deliberately lands on a fresh name rather than
        // overwriting, so a second save of a hand-edited file costs the user a
        // duplicate rather than their edits.
        let target = action == .writeAlongside
            ? FilenameGenerator.resolveCollision(name, in: directory)
            : name

        let url = directory.appendingPathComponent(target)

        // `unchanged` means the bytes are already correct, so writing them again
        // would churn the mtime and wake every watcher on the folder for no
        // reason. The file is reported as saved either way — from the
        // extension's point of view the conversation is on disk, which is what
        // it asked about.
        if action != .unchanged {
            try writeAtomically(document, to: url, directory: directory)
        } else if !FileManager.default.fileExists(atPath: url.path) {
            // Defensive: `unchanged` implies an existing file, so this should be
            // unreachable. Writing it anyway is better than reporting a path
            // that does not exist.
            try writeAtomically(document, to: url, directory: directory)
        }

        return Result(
            path: url.path,
            action: describe(action),
            turns: conversation.turns.count,
            confidence: conversation.confidence?.score ?? 1,
            complete: conversation.confidence?.complete ?? true,
            incompleteReason: conversation.confidence?.warnings.first
        )
    }

    // MARK: - Destination

    /// Resolves and checks the folder, including any path the extension supplied.
    ///
    /// The extension is not trusted with the filesystem, so a path it names is
    /// expanded, standardised, and required to be a directory that exists and is
    /// writable. A relative path is resolved against the user's Documents rather
    /// than the working directory of whatever process launched the app.
    func resolveDirectory(_ destination: String?) throws -> URL {
        let fm = FileManager.default

        let candidate: URL
        if let destination, !destination.isEmpty {
            let expanded = (destination as NSString).expandingTildeInPath
            candidate = URL(fileURLWithPath: expanded, relativeTo: fm.urls(for: .documentDirectory, in: .userDomainMask).first)
                .standardizedFileURL
        } else if let first = SearchService.folders().first {
            candidate = first
        } else {
            throw Failure.noDestination
        }

        // A default folder that does not exist means nothing is *configured*,
        // which is a different problem from a destination that exists and
        // cannot be written, and the user fixes them differently. The tool will
        // not create a folder the user did not ask for.
        if destination == nil, !fm.fileExists(atPath: candidate.path) {
            throw Failure.noDestination
        }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            throw Failure.unwritable(candidate.path)
        }
        guard isDirectory.boolValue else {
            throw Failure.unwritable(candidate.path)
        }
        guard fm.isWritableFile(atPath: candidate.path) else {
            throw Failure.unwritable(candidate.path)
        }
        return candidate
    }

    /// The file a conversation would update, if one exists.
    ///
    /// A conversation's fingerprint is written into its own frontmatter, so the
    /// existing file is found by scanning for a match rather than by guessing a
    /// title — a renamed thread still resolves to the same file.
    ///
    /// The match is a *prefix* match, not an equality, and that distinction is
    /// the whole function. A fingerprint identifies a conversation's content
    /// exactly, so a thread that has grown since it was saved hashes
    /// differently — and matching on equality alone meant every re-save of a
    /// continued thread created a new file. Checking that the file's turns are a
    /// prefix of the incoming turns finds the same file whether the thread has
    /// gained five turns or none.
    ///
    /// The prefix comparison runs on normalised turn bodies via `Fingerprint`,
    /// so whitespace differences between two extraction strategies do not read
    /// as divergence.
    ///
    /// The scan reads every Markdown file in the folder, which is O(n) per
    /// save. That is acceptable for a folder of conversations and would need the
    /// archive's index to be a lookup; noted rather than optimised, because a
    /// wrong index here means the wrong file gets updated.
    private func existingFile(for conversation: Conversation, in directory: URL) -> (url: URL, text: String)? {
        let wanted = Fingerprint.canonical(conversation)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }

        // Exact matches win, so a re-save of an unchanged conversation never
        // prefers a file that merely happens to be a prefix of it.
        var prefixMatch: (url: URL, text: String)?
        var editedMatch: (url: URL, text: String)?

        for name in contents.sorted() where name.lowercased().hasSuffix(".md") {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard let fields = Frontmatter.parse(text),
                  fields[ConversationRenderer.fingerprintKey]?.isEmpty == false
            else { continue }

            let parsed = ConversationRenderer.parse(from: text)
            if Fingerprint.canonical(source: parsed.source, model: parsed.model, turns: parsed.turns) == wanted {
                return (url, text)
            }
            if prefixMatch == nil, isPrefix(of: parsed, of: conversation) {
                prefixMatch = (url, text)
            }
            // A hand-edited file no longer matches on content, so without this
            // it would look like a conversation that had never been saved — and
            // the user would get a duplicate instead of being told their edit
            // is in the way. `IncrementalSave` decides what to do about it.
            if editedMatch == nil, isEditedVersion(of: parsed, of: conversation) {
                editedMatch = (url, text)
            }
        }
        // An exact or prefix match is a better answer than an edited one, so the
        // edited case is only returned when nothing else fits.
        return prefixMatch ?? editedMatch
    }

    /// Whether `existing` looks like a hand-edited copy of `incoming`.
    ///
    /// Identical platform and model, same turn count, and enough matching turns
    /// at the same positions to conclude it is the same thread with edits
    /// rather than a different conversation. Deliberately fuzzy in *content* and
    /// strict in *shape* — the turn count is the thing an edit cannot silently
    /// change without the user also editing the frontmatter, and a thread that
    /// has genuinely grown is caught by the prefix check instead.
    private func isEditedVersion(
        of existing: ConversationRenderer.ParsedDocument,
        of incoming: Conversation
    ) -> Bool {
        guard existing.turns.count == incoming.turns.count else { return false }
        guard existing.source == incoming.source else { return false }
        guard (existing.model ?? "") == (incoming.model ?? "") else { return false }

        // At least half the turns must line up. Demanding all of them would fail
        // for the ordinary case of editing one turn in a long thread; demanding
        // none would match unrelated conversations on the same platform.
        let same = zip(existing.turns, incoming.turns).reduce(into: 0) { count, pair in
            if pair.0.role == pair.1.role
                && Fingerprint.normalise(pair.0.body) == Fingerprint.normalise(pair.1.body) {
                count += 1
            }
        }
        return same * 2 >= incoming.turns.count
    }

    /// Whether `existing` is an earlier state of `incoming`.
    ///
    /// Requires the same platform and model, and that every turn in `existing`
    /// is present, in order and unchanged, at the head of `incoming`. Anything
    /// shorter is not the same thread.
    private func isPrefix(
        of existing: ConversationRenderer.ParsedDocument,
        of incoming: Conversation
    ) -> Bool {
        guard existing.turns.count <= incoming.turns.count else { return false }
        guard existing.source == incoming.source else { return false }
        guard (existing.model ?? "") == (incoming.model ?? "") else { return false }

        return zip(existing.turns, incoming.turns).allSatisfy { old, new in
            old.role == new.role
                && Fingerprint.normalise(old.body) == Fingerprint.normalise(new.body)
        }
    }

    private func writeAtomically(_ text: String, to url: URL, directory: URL) throws {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.unwritable(directory.path)
        }
    }

    /// The action as the extension reports it. Not an enum name, because the
    /// JavaScript side treats it as an opaque string and a rename on either side
    /// should be visible rather than silently mismatched.
    func describe(_ action: SaveAction) -> String {
        switch action {
        case .writeNew: return "writeNew"
        case .unchanged: return "unchanged"
        case .append: return "append"
        case .rewrite: return "rewrite"
        case .writeAlongside: return "writeAlongside"
        }
    }
}

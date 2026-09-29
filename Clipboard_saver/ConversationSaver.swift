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

    /// Where configured destinations come from. Injectable for the same reason
    /// the resolver takes them: a test must not write to the user's real
    /// settings.
    var defaults: UserDefaults = .standard

    /// Asks for a filename. `nil` when the user cancels.
    var requestFilename: (_ suggested: String, _ directory: URL) -> String?

    init(requestFilename: @escaping (String, URL) -> String? = { _, _ in nil }) {
        self.requestFilename = requestFilename
    }

    /// Saves against a destination.
    ///
    /// A destination named by the user's own configuration wins over one supplied
    /// by the extension: the extension is a separate process and is not the thing
    /// that should decide where anything is written.
    func save(
        _ conversation: Conversation,
        destination: String?,
        behaviour: BridgeRequest.Behaviour,
        preset: String? = nil
    ) throws -> Result {
        if let preset {
            return try write(conversation, into: DestinationResolver.resolve(preset: preset, defaults: defaults), behaviour: behaviour)
        }
        if let destination {
            return try write(
                conversation,
                into: Destination.resolve(preset: nil, path: destination),
                behaviour: behaviour
            )
        }
        // Nothing named, so this is the fallback rather than a configuration.
        let folder = try check(DestinationResolver.defaultDirectory() ?? URL(fileURLWithPath: "/"), configured: false)
        return try write(conversation, into: .separate(folder), behaviour: behaviour)
    }

    /// The real save, against a resolved destination.
    func write(
        _ conversation: Conversation,
        into destination: Destination,
        behaviour: BridgeRequest.Behaviour
    ) throws -> Result {
        let directory = try check(destination.directory)
        switch destination {
        case .separate: return try saveSeparate(conversation, into: directory, behaviour: behaviour)
        case .daily: return try saveDaily(conversation, into: directory)
        case .append(let url, _): return try saveAppending(conversation, into: url)
        }
    }

    // MARK: - One file per conversation

    private func saveSeparate(
        _ conversation: Conversation,
        into directory: URL,
        behaviour: BridgeRequest.Behaviour
    ) throws -> Result {
        let existing = existingFile(for: conversation, in: directory)
        // A hand-edited file stops matching, because the edit is precisely what
        // the comparison looks at. So the decline has to be recorded here rather
        // than discovered later: the file is found, recognised as not-updatable,
        // and the save is reported as the deliberate `writeAlongside` it is.
        let action = IncrementalSave.decide(existing: existing?.text, incoming: conversation)
        let document = IncrementalSave.apply(action, incoming: conversation, existing: existing?.text)
            ?? ConversationRenderer.render(conversation)

        // Name the file the conversation already has, when there is one.
        //
        // Deriving a name from the title and letting the generator resolve the
        // collision looks equivalent and is not: on an `unchanged` re-save nothing
        // is written, so no file exists at the resolved path, and the *next* save
        // then finds a collision and picks "Thread (1).md" -- a different
        // filename, therefore a different fingerprint, therefore a brand new
        // conversation. Three files from one thread.
        let suggested: String
        if let existing, action != .writeAlongside {
            suggested = existing.url.lastPathComponent
        } else {
            suggested = DestinationResolver.filename(for: conversation, at: .separate(directory))
        }

        let name: String
        switch behaviour {
        case .auto:
            name = suggested
        case .ask:
            guard let chosen = requestFilename(suggested, directory) else { throw Failure.cancelled }
            name = chosen
        }

        let target = action == .writeAlongside
            ? FilenameGenerator.resolveCollision(name, in: directory)
            : name
        let url = directory.appendingPathComponent(target)

        // `unchanged` means the bytes are already correct, so writing them again
        // would churn the mtime and wake every watcher on the folder for no
        // reason.
        if action != .unchanged || !FileManager.default.fileExists(atPath: url.path) {
            try writeAtomically(document, to: url, directory: directory)
        }

        return result(path: url, action: describe(action), conversation: conversation)
    }

    // MARK: - Daily note

    /// Merges a conversation into one dated file.
    ///
    /// A daily note is not a file this tool wrote: it has the user's own prose,
    /// no frontmatter and no body hash, so `IncrementalSave` would correctly
    /// classify it as foreign and decline. The section mechanism exists for
    /// exactly this case, and everything outside a marked section is the user's
    /// and is never rewritten.
    private func saveDaily(_ conversation: Conversation, into directory: URL) throws -> Result {
        let url = directory.appendingPathComponent(
            DestinationResolver.filename(for: conversation, at: .daily(directory))
        )

        let exists = FileManager.default.fileExists(atPath: url.path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        // A file that exists but does not read as text is not something to
        // rewrite. `String(contentsOf:)` failing is the signal.
        if exists && existing.isEmpty { throw Failure.unwritable(url.path) }

        let action = DailyNote.decide(note: existing, conversation: conversation)
        guard let updated = DailyNote.apply(action, note: existing, conversation: conversation) else {
            return result(path: url, action: "unchanged", conversation: conversation)
        }
        try writeAtomically(updated, to: url, directory: directory)

        let label: String
        switch action {
        case .replace: label = "replace"
        case .insert: label = exists ? "insert" : "writeNew"
        case .unchanged, .refuse: label = "unchanged"
        }
        return result(path: url, action: label, conversation: conversation)
    }

    // MARK: - One growing file

    /// Appends to a single named file, so one platform's conversations
    /// accumulate in one place.
    ///
    /// Not the default and not deduplicated: an append-only file has no
    /// per-conversation identity, so the same conversation saved twice appears
    /// twice with no way to take one out. That is acceptable for a deliberate log
    /// and not acceptable as a default.
    private func saveAppending(_ conversation: Conversation, into url: URL) throws -> Result {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if exists && existing.isEmpty { throw Failure.unwritable(url.path) }

        let updated = DailyNote.appending(DailyNote.makeSection(conversation), to: existing)
        try writeAtomically(updated, to: url, directory: url.deletingLastPathComponent())
        return result(path: url, action: exists ? "insert" : "writeNew", conversation: conversation)
    }

    // MARK: - Results

    private func result(path: URL, action: String, conversation: Conversation) -> Result {
        Result(
            path: path.path,
            action: action,
            turns: conversation.turns.count,
            confidence: conversation.confidence?.score ?? 1,
            complete: conversation.confidence?.complete ?? true,
            incompleteReason: conversation.confidence?.warnings.first
        )
    }

    /// Checks a directory exists, is a directory, and is writable.
    ///
    /// - Parameter configured: `true` when the folder came from the user's own
    ///   settings rather than a fallback. A *missing* fallback folder means
    ///   nothing is configured, which the user fixes by choosing a destination;
    ///   a missing configured folder means something is wrong with it, which they
    ///   fix by creating it. Reporting the same error for both sends them to the
    ///   wrong place.
    private func check(_ candidate: URL, configured: Bool = true) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: candidate.path) else {
            if configured { throw Failure.unwritable(candidate.path) }
            throw Failure.noDestination
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            throw Failure.unwritable(candidate.path)
        }
        guard isDirectory.boolValue else { throw Failure.unwritable(candidate.path) }
        guard fm.isWritableFile(atPath: candidate.path) else {
            throw Failure.unwritable(candidate.path)
        }
        return candidate
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

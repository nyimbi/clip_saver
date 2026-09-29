import Foundation

/// Walks a folder of Markdown files and brings the index up to date.
///
/// The database is a derived artefact, so this has to be able to rebuild from
/// nothing. That property is what makes the rest of the design safe: any index
/// bug costs a rebuild, not a user's archive.
struct ArchiveIndexer {

    enum Failure: Error, CustomStringConvertible {
        case notMarkdown(String)

        var description: String {
            switch self {
            case .notMarkdown(let path):
                return "\(path) is not a Markdown file."
            }
        }
    }

    /// What a pass did, so a caller can report honestly rather than implying a
    /// complete rebuild when it skipped files.
    struct Report: Equatable {
        /// A file that could not be read. Named rather than a tuple so the report
        /// can be compared in tests.
        struct Failure: Equatable {
            var path: String
            var reason: String
        }

        var indexed = 0
        var unchanged = 0
        var removed = 0
        var skipped: [String] = []
        var failed: [Failure] = []

        var total: Int { indexed + unchanged }
    }

    let store: ArchiveStore

    init(store: ArchiveStore) { self.store = store }

    /// Indexes every Markdown file under `folder`, recursively.
    ///
    /// - Parameter force: ignore mtimes and re-read everything. Used after a
    ///   format change, when a file's mtime is no longer evidence that the
    ///   index is current.
    @discardableResult
    func indexFolder(_ folder: URL, force: Bool = false) throws -> Report {
        var report = Report()
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return report }

        var seen = Set<String>()
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            seen.insert(url.standardizedFileURL.path)
            do {
                try indexFile(url, force: force, report: &report)
            } catch {
                // One unreadable file must not abort the pass. A folder with a
                // single permission-denied file would otherwise never index.
                report.failed.append(Report.Failure(path: url.lastPathComponent, reason: "\(error)"))
            }
        }

        // Forget files that have been deleted or moved. Only paths already in the
        // index are considered, so this can never remove an entry for a file
        // that simply lives in another folder.
        for path in try store.allPaths() where !seen.contains(path) {
            try store.removeDocument(atPath: path)
            report.removed += 1
        }

        return report
    }

    /// Indexes one file, skipping it when nothing has changed.
    func indexFile(_ url: URL, force: Bool = false, report: inout Report) throws {
        guard url.pathExtension.lowercased() == "md" else { throw Failure.notMarkdown(url.path) }

        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values.fileSize ?? 0
        let path = url.standardizedFileURL.path

        if !force, let existing = try store.document(withPath: path) {
            // mtime plus size is enough to skip the read. A same-second edit that
            // preserves the file size is missed, which is the trade for not
            // re-reading every file on every launch; `force` exists for when that
            // matters.
            if abs(existing.mtime - mtime) < 0.000_001 && existing.byteSize == size {
                report.unchanged += 1
                return
            }
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = ConversationRenderer.parse(from: text)
        let metadata = Self.metadata(from: text, parsed: parsed, mtime: mtime, size: size)

        try store.index(parsed: parsed, atPath: path, metadata: metadata)
        report.indexed += 1
    }

    /// Reads what the frontmatter claims and tags the content.
    ///
    /// A file the saver wrote carries its own fingerprint. A file from another
    /// tool does not, and is not given one here: the fingerprint is how the
    /// saver recognises its own output on re-save, and inventing one for a
    /// foreign file would make the archive claim authorship of something it did
    /// not write. Those files are still fully searchable, which is the point of
    /// building an index over a folder rather than a private database.
    static func metadata(
        from text: String,
        parsed: ConversationRenderer.ParsedDocument,
        mtime: Double,
        size: Int
    ) -> DocumentMetadata {
        let fields = Frontmatter.parse(text) ?? [:]
        let source = ConversationSource(rawValue: platformSlug(from: fields["platform"]) ?? "")
        let url = fields["url"].flatMap(URL.init(string:))

        let conversation = Conversation(
            title: fields["title"],
            source: source,
            model: fields["model"],
            url: url,
            turns: parsed.turns
        )

        return DocumentMetadata(
            title: fields["title"],
            platform: fields["platform"],
            model: fields["model"],
            url: url,
            fingerprint: fields[ConversationRenderer.fingerprintKey],
            mtime: mtime,
            byteSize: size,
            incomplete: fields["incomplete"] == "true",
            tags: ContentTagger.tags(for: conversation)
        )
    }

    /// Maps a display name back to a raw source, so a file records the same slug
    /// the saver would have written.
    static func platformSlug(from displayName: String?) -> String? {
        guard let displayName else { return nil }
        for source in [ConversationSource.chatgpt, .claude, .gemini, .perplexity, .copilot, .webPage] {
            if source.displayName.caseInsensitiveCompare(displayName) == .orderedSame {
                return source.rawValue
            }
        }
        return displayName.lowercased()
    }
}

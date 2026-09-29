import Foundation

/// The local index over saved Markdown files.
///
/// This is the part nobody else in this market has. Everyone's exporter
/// produces files; nobody's exporter makes the resulting pile findable six
/// months later, and nobody stops you accumulating fourteen copies of the same
/// thread. That gap is the whole argument for building the archive rather than
/// yet another exporter.
///
/// Design constraints, in priority order:
///
///   1. **The files are the source of truth.** The database is a derived index
///      and can be deleted and rebuilt from a folder at any time. Nothing is
///      stored here that is not recoverable from the Markdown, because a
///      database that can lose data is worse than no database.
///   2. **Index turns, not files.** A hit should point at the message that
///      matched, not at a 400-turn conversation the user then has to scan.
///   3. **Never destructive.** Indexing cannot delete or edit a user's file.
struct ArchiveStore {

    /// Where the index lives by default.
    ///
    /// Application Support rather than the app bundle: it must be writable, and
    /// it must survive an app update.
    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Clipboard_saver", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("archive.db")
    }

    let database: SQLiteDatabase

    /// Opens or creates the store.
    init(url: URL? = nil, inMemory: Bool = false) throws {
        let path: String
        if inMemory {
            path = ":memory:"
        } else {
            path = (try url ?? Self.defaultURL()).path
        }
        database = try SQLiteDatabase(path: path, inMemory: inMemory)
        try migrate()
    }

    // MARK: - Schema

    /// `schemaVersion` is stored in the same transaction as the migration so a
    /// half-applied upgrade cannot leave the version claiming success.
    private static let schemaVersion = 1

    private func migrate() throws {
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)

        // One row per indexed file. `fingerprint` is what makes re-indexing
        // idempotent; `mtime` is the cheap pre-check that avoids re-reading an
        // unchanged file at all.
        try database.execute("""
            CREATE TABLE IF NOT EXISTS documents (
                id           INTEGER PRIMARY KEY,
                path         TEXT    NOT NULL UNIQUE,
                title        TEXT    NOT NULL DEFAULT '',
                platform     TEXT    NOT NULL DEFAULT '',
                model        TEXT,
                url          TEXT,
                fingerprint  TEXT    NOT NULL DEFAULT '',
                turn_count   INTEGER NOT NULL DEFAULT 0,
                content_hash TEXT    NOT NULL DEFAULT '',
                mtime        REAL    NOT NULL DEFAULT 0,
                byte_size    INTEGER NOT NULL DEFAULT 0,
                incomplete   INTEGER NOT NULL DEFAULT 0,
                indexed_at   REAL    NOT NULL DEFAULT 0
            )
            """)

        try database.execute("""
            CREATE TABLE IF NOT EXISTS messages (
                id          INTEGER PRIMARY KEY,
                document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                turn        INTEGER NOT NULL,
                role        TEXT    NOT NULL,
                body        TEXT    NOT NULL,
                UNIQUE (document_id, turn)
            )
            """)

        // A standalone FTS table rather than an external-content one. It stores
        // a second copy of every message body, which is a deliberate trade: the
        // alternative needs triggers to keep the index in step with deletes and
        // makes a partial rebuild much easier to get subtly wrong. A rebuild
        // from disk is a supported operation here, so duplication is cheap.
        try database.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                body,
                content = 'messages',
                content_rowid = 'id',
                tokenize = 'porter unicode61'
            )
            """)

        try database.execute("""
            CREATE TABLE IF NOT EXISTS tags (
                document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                tag         TEXT    NOT NULL,
                UNIQUE (document_id, tag)
            )
            """)

        try database.execute("CREATE INDEX IF NOT EXISTS documents_fingerprint ON documents(fingerprint)")
        try database.execute("CREATE INDEX IF NOT EXISTS messages_document ON messages(document_id, turn)")
        try database.execute("CREATE INDEX IF NOT EXISTS tags_tag ON tags(tag)")

        try database.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', ?)", [
            .text(String(Self.schemaVersion))
        ])
    }

    /// Whether this build of SQLite has FTS5. Checked once and reported, rather
    /// than assumed, because the module can be compiled out — Apple's system
    /// libsqlite3 ships it, but a Homebrew or Python-linked one may not.
    static func fts5Available(_ database: SQLiteDatabase) -> Bool {
        (try? database.scalarInt("SELECT 1 FROM pragma_compile_options WHERE compile_options LIKE '%FTS5%'")) ?? 0
            == 1
    }

    // MARK: - Documents

    /// Removes a document and its messages. Only ever called for a file that has
    /// disappeared from disk, so it is not a destructive path for live data.
    func removeDocument(atPath path: String) throws {
        try database.run("DELETE FROM documents WHERE path = ?", [.text(path)])
    }

    func documentCount() throws -> Int { Int(try database.scalarInt("SELECT count(*) FROM documents")) }

    func messageCount() throws -> Int { Int(try database.scalarInt("SELECT count(*) FROM messages")) }

    func document(withPath path: String) throws -> Document? {
        try database.query("SELECT * FROM documents WHERE path = ?", [.text(path)]) { Document(row: $0) }.first
    }

    /// Every indexed path, for a bulk operation.
    func allPaths() throws -> [String] {
        try database.query("SELECT path FROM documents ORDER BY path") { $0.string(0) ?? "" }
    }

    // MARK: - Indexing one document

    /// Replaces the index entry for one file.
    ///
    /// A single transaction: a half-applied index would leave a document whose
    /// message count disagrees with its turn count, and the next rebuild would
    /// produce a different answer than the search results the user just saw.
    func index(
        parsed: ConversationRenderer.ParsedDocument,
        atPath path: String,
        metadata: DocumentMetadata
    ) throws {
        let turns = parsed.turns
        let contentHash = Fingerprint.digest(
            Conversation(
                title: metadata.title,
                source: ConversationSource(rawValue: metadata.platform ?? ""),
                model: metadata.model,
                url: metadata.url,
                turns: turns
            )
        )

        try database.execute("BEGIN IMMEDIATE")
        do {
            if let existing = try document(withPath: path) {
                // `ON DELETE CASCADE` clears the messages, but the FTS index
                // holds its own copy and does not see the cascade, so its rows
                // are removed explicitly.
                try database.run("DELETE FROM messages_fts WHERE rowid IN (SELECT id FROM messages WHERE document_id = ?)", [
                    .integer(existing.id)
                ])
                try database.run("DELETE FROM messages WHERE document_id = ?", [.integer(existing.id)])
                try database.run("DELETE FROM tags WHERE document_id = ?", [.integer(existing.id)])
                // The document row itself is deleted rather than updated, so the
                // `UNIQUE(path)` constraint cannot reject the insert that
                // replaces it. Updating in place would need the same twelve
                // columns listed twice, which is exactly the kind of drift that
                // silently leaves a stale field behind.
                try database.run("DELETE FROM documents WHERE id = ?", [.integer(existing.id)])
            }

            try database.run(
                """
                INSERT INTO documents
                    (path, title, platform, model, url, fingerprint, turn_count,
                     content_hash, mtime, byte_size, incomplete, indexed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(path),
                    .text(metadata.title ?? ""),
                    .text(metadata.platform ?? ""),
                    .text(metadata.model),
                    .text(metadata.url?.absoluteString),
                    .text(metadata.fingerprint ?? ""),
                    .integer(turns.count),
                    .text(contentHash),
                    .real(metadata.mtime),
                    .integer(metadata.byteSize),
                    .integer(metadata.incomplete ? 1 : 0),
                    .real(Date().timeIntervalSince1970),
                ]
            )

            let id = try database.scalarInt("SELECT id FROM documents WHERE path = ?", [.text(path)])
            for (turn, item) in turns.enumerated() {
                try database.run(
                    "INSERT INTO messages (document_id, turn, role, body) VALUES (?, ?, ?, ?)",
                    [.integer(id), .integer(turn), .text(item.role.rawValue), .text(item.body)]
                )
                let messageId = try database.scalarInt(
                    "SELECT id FROM messages WHERE document_id = ? AND turn = ?",
                    [.integer(id), .integer(turn)]
                )
                try database.run("INSERT INTO messages_fts (rowid, body) VALUES (?, ?)", [
                    .integer(messageId), .text(item.body),
                ])
            }

            for tag in metadata.tags {
                try database.run("INSERT OR IGNORE INTO tags (document_id, tag) VALUES (?, ?)", [
                    .integer(id), .text(tag),
                ])
            }

            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Search

    /// Full-text search over message bodies.
    ///
    /// Results are at turn granularity, which is the reason for indexing
    /// messages rather than documents: a 400-turn conversation that matched on
    /// one message should not return the other 399.
    func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let expression = try FTSQuery(raw: query)
        return try database.query(
            """
            SELECT d.path, d.title, d.platform, m.turn, m.role, m.body,
                   snippet(messages_fts, 0, '<<', '>>', '…', 14) AS snip,
                   bm25(messages_fts) AS score
            FROM messages_fts
            JOIN messages  m ON m.id = messages_fts.rowid
            JOIN documents d ON d.id = m.document_id
            WHERE messages_fts MATCH ?
            ORDER BY score
            LIMIT ?
            """,
            [.text(expression.raw), .integer(limit)]
        ) {
            SearchHit(
                path: $0.string(0) ?? "",
                title: $0.string(1, default: ""),
                platform: $0.string(2, default: ""),
                turn: Int($0.int(3)),
                role: $0.string(4, default: "user"),
                snippet: $0.string(6) ?? "",
                score: $0.double(7)
            )
        }
    }

    /// Paths grouped by fingerprint, so the caller can find the same
    /// conversation saved under several names. Exact by construction; a
    /// near-duplicate needs content similarity and is a separate question.
    ///
    /// Rows come back ordered by fingerprint, so each group is a run of
    /// consecutive rows and the grouping is a single pass with no sort in Swift.
    func duplicateGroups() throws -> [[String]] {
        let rows = try database.query(
            """
            SELECT fingerprint, path FROM documents
            WHERE fingerprint != ''
            ORDER BY fingerprint, path
            """
        ) { (fingerprint: $0.string(0) ?? "", path: $0.string(1) ?? "") }

        var groups: [[String]] = []
        var current: (key: String, paths: [String])?
        for row in rows {
            if var open = current, open.key == row.fingerprint {
                open.paths.append(row.path)
                current = open
            } else {
                if let open = current, open.paths.count > 1 { groups.append(open.paths) }
                current = (row.fingerprint, [row.path])
            }
        }
        if let open = current, open.paths.count > 1 { groups.append(open.paths) }
        return groups
    }
}

/// A row of the `documents` table.
struct Document {
    var id: Int64
    var path: String
    var title: String
    var platform: String
    var model: String?
    var url: String?
    var fingerprint: String
    var turnCount: Int
    var contentHash: String
    var mtime: Double
    var byteSize: Int
    var incomplete: Bool
    var indexedAt: Double

    init(row: Row) {
        id = row.int(0)
        path = row.string(1) ?? ""
        title = row.string(2, default: "")
        platform = row.string(3, default: "")
        model = row.string(4)
        url = row.string(5)
        fingerprint = row.string(6, default: "")
        turnCount = Int(row.int(7))
        contentHash = row.string(8, default: "")
        mtime = row.double(9)
        byteSize = Int(row.int(10))
        incomplete = row.int(11) != 0
        indexedAt = row.double(12)
    }
}

/// What the indexer knows about a file that is not in the turns themselves.
struct DocumentMetadata {
    var title: String?
    var platform: String?
    var model: String?
    var url: URL?
    /// Recorded at write time by the saver. The archive's own recomputation is
    /// a cross-check, not a replacement — a file written by another tool has no
    /// fingerprint, and must not be given one it did not choose.
    var fingerprint: String?
    var mtime: Double
    var byteSize: Int
    var incomplete: Bool
    var tags: [String]

    init(
        title: String? = nil,
        platform: String? = nil,
        model: String? = nil,
        url: URL? = nil,
        fingerprint: String? = nil,
        mtime: Double = 0,
        byteSize: Int = 0,
        incomplete: Bool = false,
        tags: [String] = []
    ) {
        self.title = title
        self.platform = platform
        self.model = model
        self.url = url
        self.fingerprint = fingerprint
        self.mtime = mtime
        self.byteSize = byteSize
        self.incomplete = incomplete
        self.tags = tags
    }
}

struct SearchHit {
    var path: String
    var title: String
    var platform: String
    var turn: Int
    var role: String
    var snippet: String
    /// bm25 is negative, with lower meaning a better match.
    var score: Double
}

    /// A query prepared for FTS5.
    ///
    /// A struct rather than an enum: it carries the translated string, and a type
    /// that exists only to hold a value should not be pretending to be a closed
    /// set of cases.
    struct FTSQuery {
        /// A value that was only whitespace, so there is nothing to search for.
        struct Empty: Error, CustomStringConvertible {
            var description: String { "Enter something to search for." }
        }

        let raw: String

        init(raw: String) throws {
            let tokens = Self.tokenise(raw)
            guard !tokens.isEmpty else { throw Empty() }
            self.raw = tokens.joined(separator: " ")
        }

        /// A quoted term, or a quoted prefix term.
        ///
        /// FTS5's query language treats `AND`, `OR`, `*`, `"`, `-`, `:` and `(`
        /// as operators, and an unescaped query is a *syntax error* — which
        /// surfaces as zero results, reading as "nothing matched" rather than
        /// "your query was invalid". The most misleading failure available, so
        /// every token is quoted. A trailing `*` is kept, because prefix search
        /// is the one piece of real syntax worth offering.
        static func tokenise(_ query: String) -> [String] {
            let separated = query
                .replacingOccurrences(of: "\"", with: " ")
                .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                .filter { !$0.isEmpty }

            return separated.map { token in
                let prefix = token.hasSuffix("*")
                let stem = prefix ? String(token.dropLast()) : token
                // A doubled quote is FTS5's escape for a literal one.
                let escaped = stem.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\(prefix ? "*" : "")\""
            }
        }
    }

import Foundation
import XCTest
@testable import Clipboard_saver

/// Tests for the archive index.
///
/// Every test here runs against an in-memory database and a temporary folder.
/// The user's real archive is at a fixed path in Application Support, and a
/// test that reached it would be a test that destroys data.
final class ArchiveStoreTests: XCTestCase {

    private func store() throws -> ArchiveStore {
        try ArchiveStore(inMemory: true)
    }

    private func metadata(
        title: String = "T",
        fingerprint: String? = nil,
        tags: [String] = []
    ) -> DocumentMetadata {
        DocumentMetadata(
            title: title,
            platform: "Claude",
            model: "claude-opus-5",
            url: URL(string: "https://claude.ai/chat/abc"),
            fingerprint: fingerprint,
            mtime: 1000,
            byteSize: 200,
            tags: tags
        )
    }

    private func conversation(_ bodies: [(TurnRole, String)]) -> Conversation {
        Conversation(
            title: "T", source: .claude, model: "claude-opus-5",
            turns: bodies.map { Turn(role: $0.0, body: $0.1) }
        )
    }

    private func parsed(_ bodies: [(TurnRole, String)]) -> ConversationRenderer.ParsedDocument {
        let rendered = ConversationRenderer.render(conversation(bodies))
        return ConversationRenderer.parse(from: rendered)
    }

    // MARK: - Schema

    func testFreshStoreIsUsable() throws {
        let store = try store()
        XCTAssertEqual(try store.documentCount(), 0)
        XCTAssertEqual(try store.messageCount(), 0)
    }

    func testSchemaVersionIsRecorded() throws {
        let archive = try store()
        let version = try archive.database.scalarInt("SELECT value FROM meta WHERE key = 'schema_version'")
        XCTAssertEqual(version, 1)
    }

    /// FTS5 can be compiled out of a SQLite build. Apple's system library has
    /// it; a Homebrew or statically linked one might not, and the archive has to
    /// be able to say so rather than fail mysteriously at search time.
    func testFTS5IsAvailableInThisBuild() throws {
        let archive = try store()
        XCTAssertTrue(ArchiveStore.fts5Available(archive.database))
    }

    // MARK: - Indexing

    func testIndexingADocumentRecordsItsTurns() throws {
        let store = try store()
        try store.index(
            parsed: parsed([(.user, "question"), (.assistant, "answer")]),
            atPath: "/tmp/a.md",
            metadata: metadata()
        )
        XCTAssertEqual(try store.documentCount(), 1)
        XCTAssertEqual(try store.messageCount(), 2)
    }

    func testIndexedDocumentKeepsItsMetadata() throws {
        let store = try store()
        try store.index(parsed: parsed([(.user, "q")]), atPath: "/tmp/a.md", metadata: metadata(title: "Saved"))
        let document = try XCTUnwrap(store.document(withPath: "/tmp/a.md"))
        XCTAssertEqual(document.title, "Saved")
        XCTAssertEqual(document.platform, "Claude")
        XCTAssertEqual(document.model, "claude-opus-5")
        XCTAssertEqual(document.turnCount, 1)
    }

    /// Re-indexing the same path must replace, not accumulate. A second pass
    /// over the same folder is the normal case, and duplicates in the index
    /// would make every search return each hit twice.
    func testReindexingTheSamePathReplacesRatherThanDuplicates() throws {
        let store = try store()
        let path = "/tmp/a.md"
        try store.index(parsed: parsed([(.user, "first")]), atPath: path, metadata: metadata())
        try store.index(parsed: parsed([(.user, "first"), (.assistant, "second")]), atPath: path, metadata: metadata())
        XCTAssertEqual(try store.documentCount(), 1)
        XCTAssertEqual(try store.messageCount(), 2)
    }

    /// The FTS table holds its own copy of the text, so a replaced document's old
    /// rows have to be removed explicitly. `ON DELETE CASCADE` clears
    /// `messages` but the FTS index does not see the cascade.
    func testReindexingDoesNotLeaveStaleSearchRows() throws {
        let store = try store()
        let path = "/tmp/a.md"
        try store.index(parsed: parsed([(.user, "originaltext")]), atPath: path, metadata: metadata())
        try store.index(parsed: parsed([(.user, "replacementtext")]), atPath: path, metadata: metadata())
        XCTAssertTrue(try store.search("originaltext").isEmpty, "stale text is still searchable")
        XCTAssertEqual(try store.search("replacementtext").count, 1)
    }

    func testRemovingADocumentClearsItsMessages() throws {
        let store = try store()
        try store.index(parsed: parsed([(.user, "gone soon")]), atPath: "/tmp/a.md", metadata: metadata())
        try store.removeDocument(atPath: "/tmp/a.md")
        XCTAssertEqual(try store.documentCount(), 0)
        XCTAssertEqual(try store.messageCount(), 0)
        XCTAssertTrue(try store.search("gone soon").isEmpty)
    }

    func testIncompleteFlagIsStored() throws {
        let store = try store()
        var meta = metadata()
        meta.incomplete = true
        try store.index(parsed: parsed([(.user, "q")]), atPath: "/tmp/a.md", metadata: meta)
        XCTAssertEqual(try store.document(withPath: "/tmp/a.md")?.incomplete, true)
    }

    // MARK: - Search

    func testSearchFindsAMessage() throws {
        let store = try store()
        try store.index(
            parsed: parsed([(.user, "how do actors work"), (.assistant, "they own state")]),
            atPath: "/tmp/a.md",
            metadata: metadata()
        )
        let hits = try store.search("actors")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].path, "/tmp/a.md")
        XCTAssertEqual(hits[0].role, "user")
        XCTAssertEqual(hits[0].turn, 0)
    }

    /// The reason messages are indexed instead of documents: a hit should point
    /// at the turn that matched.
    func testSearchReturnsTheMatchingTurnNotTheWholeDocument() throws {
        let store = try store()
        let turns: [(TurnRole, String)] = [
            (.user, "first question about actors"),
            (.assistant, "unrelated answer"),
            (.user, "third question"),
        ]
        try store.index(parsed: parsed(turns), atPath: "/tmp/a.md", metadata: metadata())
        let hits = try store.search("actors")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].turn, 0)
    }

    func testSearchSnippetContainsTheMatch() throws {
        let store = try store()
        try store.index(
            parsed: parsed([(.assistant, "the answer is 42 and that is definitive")]),
            atPath: "/tmp/a.md",
            metadata: metadata()
        )
        let hit = try XCTUnwrap(try store.search("definitive").first)
        XCTAssertTrue(hit.snippet.contains("definitive"))
    }

    func testSearchIsCaseInsensitive() throws {
        let store = try store()
        try store.index(parsed: parsed([(.user, "Actors and States")]), atPath: "/tmp/a.md", metadata: metadata())
        XCTAssertEqual(try store.search("actors").count, 1)
        XCTAssertEqual(try store.search("ACTORS").count, 1)
    }

    /// The porter stemmer is why "actors" finds "actor" — a user searching for
    /// a concept should not have to guess the exact inflection the model used.
    func testSearchStemsWords() throws {
        let store = try store()
        try store.index(parsed: parsed([(.user, "running and jumping")]), atPath: "/tmp/a.md", metadata: metadata())
        XCTAssertEqual(try store.search("run").count, 1)
    }

    func testSearchAcrossDocuments() throws {
        let store = try store()
        try store.index(parsed: parsed([(.user, "swift actors")]), atPath: "/tmp/a.md", metadata: metadata())
        try store.index(parsed: parsed([(.user, "rust actors")]), atPath: "/tmp/b.md", metadata: metadata())
        XCTAssertEqual(try store.search("actors").count, 2)
    }

    func testSearchRespectsTheLimit() throws {
        let store = try store()
        for i in 0..<10 {
            try store.index(
                parsed: parsed([(.user, "shared word \(i)")]),
                atPath: "/tmp/\(i).md",
                metadata: metadata()
            )
        }
        XCTAssertEqual(try store.search("shared", limit: 3).count, 3)
    }

    func testNoMatchReturnsEmpty() throws {
        let store = try store()
        try store.index(parsed: parsed([(.user, "something")]), atPath: "/tmp/a.md", metadata: metadata())
        XCTAssertTrue(try store.search("absent").isEmpty)
    }

    func testSearchingAnEmptyArchiveReturnsEmpty() throws {
        XCTAssertTrue(try store().search("anything").isEmpty)
    }

    // MARK: - Duplicates

    func testFingerprintsGroupTheSameConversationSavedTwice() throws {
        let store = try store()
        let conv = conversation([(.user, "same question"), (.assistant, "same answer")])
        let rendered = ConversationRenderer.render(conv)
        let parsedDoc = ConversationRenderer.parse(from: rendered)
        let fingerprint = Frontmatter.parse(rendered)?["fingerprint"]

        var a = metadata()
        a.fingerprint = fingerprint
        var b = metadata()
        b.fingerprint = fingerprint
        try store.index(parsed: parsedDoc, atPath: "/tmp/a.md", metadata: a)
        try store.index(parsed: parsedDoc, atPath: "/tmp/b.md", metadata: b)

        let groups = try store.duplicateGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0], ["/tmp/a.md", "/tmp/b.md"])
    }

    func testDifferentConversationsAreNotGrouped() throws {
        let store = try store()
        try store.index(parsed: parsed([(.user, "one")]), atPath: "/tmp/a.md", metadata: metadata(fingerprint: "a"))
        try store.index(parsed: parsed([(.user, "two")]), atPath: "/tmp/b.md", metadata: metadata(fingerprint: "b"))
        XCTAssertTrue(try store.duplicateGroups().isEmpty)
    }

    func testFilesWithoutAFingerprintAreNotGrouped() throws {
        let store = try store()
        try store.index(parsed: parsed([(.user, "x")]), atPath: "/tmp/a.md", metadata: metadata())
        try store.index(parsed: parsed([(.user, "x")]), atPath: "/tmp/b.md", metadata: metadata())
        XCTAssertTrue(try store.duplicateGroups().isEmpty)
    }

    // MARK: - Durability

    /// The index is derived data, so it must be reconstructible. This is what
    /// makes every other guarantee here cheap.
    func testIndexIsRebuildableFromDisk() throws {
        let folder = try makeFolder()
        let store = try store()
        try write(
            Conversation(title: "A", source: .claude, turns: [Turn(role: .user, body: "rebuildable content")]),
            to: folder.appendingPathComponent("a.md")
        )
        try ArchiveIndexer(store: store).indexFolder(folder)
        XCTAssertEqual(try store.search("rebuildable").count, 1)

        // Wipe and rebuild from disk into a fresh database. This is the property
        // that makes the index safe to delete: the Markdown is the source of
        // truth, and the database holds nothing it cannot regenerate.
        let rebuilt = try ArchiveStore(inMemory: true)
        try ArchiveIndexer(store: rebuilt).indexFolder(folder)
        XCTAssertEqual(try rebuilt.search("rebuildable").count, 1)
    }

    // MARK: - Helpers

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ conversation: Conversation, to url: URL) throws {
        try ConversationRenderer.render(conversation).write(to: url, atomically: true, encoding: .utf8)
    }
}

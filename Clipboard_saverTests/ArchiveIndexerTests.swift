import Foundation
import XCTest
@testable import Clipboard_saver

/// Tests for walking a folder and keeping the index current.
///
/// The central property is that the index is derived: it can be deleted and
/// rebuilt from Markdown alone. Every test here is about that surviving.
final class ArchiveIndexerTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("indexer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func archive() throws -> ArchiveStore { try ArchiveStore(inMemory: true) }

    @discardableResult
    private func writeFile(_ name: String, _ conversation: Conversation) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try ConversationRenderer.render(conversation).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeRaw(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func conversation(_ title: String, turns: [Turn]) -> Conversation {
        Conversation(title: title, source: .claude, model: "claude-opus-5", turns: turns)
    }

    // MARK: - Basics

    func testIndexesMarkdownInTheFolder() throws {
        try writeFile("a.md", conversation("A", turns: [Turn(role: .user, body: "first")]))
        try writeFile("b.md", conversation("B", turns: [Turn(role: .user, body: "second")]))

        let store = try archive()
        let report = try ArchiveIndexer(store: store).indexFolder(folder)
        XCTAssertEqual(report.indexed, 2)
        XCTAssertEqual(try store.documentCount(), 2)
    }

    func testIsRecursive() throws {
        let nested = folder.appendingPathComponent("2026", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try ConversationRenderer.render(conversation("Deep", turns: [Turn(role: .user, body: "nested content")]))
            .write(to: nested.appendingPathComponent("deep.md"), atomically: true, encoding: .utf8)

        let store = try archive()
        try ArchiveIndexer(store: store).indexFolder(folder)
        XCTAssertEqual(try store.search("nested").count, 1)
    }

    func testNonMarkdownFilesAreIgnored() throws {
        try writeFile("a.md", conversation("A", turns: [Turn(role: .user, body: "indexed")]))
        try writeRaw("notes.txt", "not markdown")
        try writeRaw("data.json", "{}")

        let store = try archive()
        let report = try ArchiveIndexer(store: store).indexFolder(folder)
        XCTAssertEqual(report.indexed, 1)
        XCTAssertEqual(try store.documentCount(), 1)
    }

    func testHiddenFilesAreIgnored() throws {
        try writeFile("a.md", conversation("A", turns: [Turn(role: .user, body: "visible")]))
        try ConversationRenderer.render(conversation("H", turns: [Turn(role: .user, body: "invisible")]))
            .write(to: folder.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)

        let store = try archive()
        try ArchiveIndexer(store: store).indexFolder(folder)
        XCTAssertTrue(try store.search("invisible").isEmpty)
        XCTAssertEqual(try store.documentCount(), 1)
    }

    // MARK: - Skipping unchanged files

    /// mtime plus size is the cheap pre-check. Re-reading every file on every
    /// search would make the archive slow exactly when it is being used.
    func testUnchangedFilesAreNotReread() throws {
        try writeFile("a.md", conversation("A", turns: [Turn(role: .user, body: "stable")]))
        let store = try archive()
        let indexer = ArchiveIndexer(store: store)

        XCTAssertEqual(try indexer.indexFolder(folder).indexed, 1)
        XCTAssertEqual(try indexer.indexFolder(folder).unchanged, 1)
    }

    func testForceRereadsEverything() throws {
        try writeFile("a.md", conversation("A", turns: [Turn(role: .user, body: "stable")]))
        let store = try archive()
        let indexer = ArchiveIndexer(store: store)

        try indexer.indexFolder(folder)
        XCTAssertEqual(try indexer.indexFolder(folder, force: true).indexed, 1)
    }

    func testEditedFileIsReindexed() throws {
        let url = try writeFile("a.md", conversation("A", turns: [Turn(role: .user, body: "original")]))
        let store = try archive()
        let indexer = ArchiveIndexer(store: store)
        try indexer.indexFolder(folder)

        // A distinct size guarantees the change is detected even within the same
        // mtime granularity as the first write.
        try ConversationRenderer.render(
            conversation("A", turns: [Turn(role: .user, body: "original plus a much longer replacement body")])
        ).write(to: url, atomically: true, encoding: .utf8)

        try indexer.indexFolder(folder)
        XCTAssertEqual(try store.search("replacement").count, 1)
        XCTAssertTrue(try store.search("original plus a much").count == 1)
    }

    // MARK: - Removal

    /// A file the user deleted must leave the index, or search keeps returning
    /// hits that cannot be opened.
    func testDeletedFilesLeaveTheIndex() throws {
        let url = try writeFile("a.md", conversation("A", turns: [Turn(role: .user, body: "temporary")]))
        let store = try archive()
        let indexer = ArchiveIndexer(store: store)
        try indexer.indexFolder(folder)
        XCTAssertEqual(try store.search("temporary").count, 1)

        try FileManager.default.removeItem(at: url)
        let report = try indexer.indexFolder(folder)
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(try store.documentCount(), 0)
        XCTAssertTrue(try store.search("temporary").isEmpty)
    }

    func testRenamedFileIsFollowed() throws {
        let url = try writeFile("a.md", conversation("A", turns: [Turn(role: .user, body: "moved content")]))
        let store = try archive()
        let indexer = ArchiveIndexer(store: store)
        try indexer.indexFolder(folder)

        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("b.md"))
        try indexer.indexFolder(folder)

        XCTAssertEqual(try store.documentCount(), 1)
        XCTAssertEqual(try store.search("moved").first?.path, folder.appendingPathComponent("b.md").standardizedFileURL.path)
    }

    // MARK: - Robustness

    /// One unreadable file must not stop a folder indexing. Otherwise a single
    /// permission-denied file means the archive silently never works.
    func testOneBadFileDoesNotAbortThePass() throws {
        try writeFile("good.md", conversation("Good", turns: [Turn(role: .user, body: "indexed content")]))
        // A file that is not valid UTF-8, standing in for a permission problem.
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: folder.appendingPathComponent("bad.md"))

        let store = try archive()
        let report = try ArchiveIndexer(store: store).indexFolder(folder)
        XCTAssertEqual(report.indexed, 1)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(try store.search("indexed").count, 1)
    }

    /// A file with no frontmatter is still worth indexing — it may have come from
    /// a competitor's exporter, which is the point of indexing a folder rather
    /// than a private database.
    func testForeignMarkdownIsIndexed() throws {
        try writeRaw("foreign.md", """
            # Someone else's notes

            ## User

            A question about widgets.

            ## Assistant

            An answer about widgets.
            """)
        let store = try archive()
        try ArchiveIndexer(store: store).indexFolder(folder)
        XCTAssertEqual(try store.search("widgets").count, 2)
        XCTAssertEqual(try store.document(withPath: folder.appendingPathComponent("foreign.md").standardizedFileURL.path)?.title, "")
    }

    /// The archive must not claim authorship of a file it did not write.
    func testForeignMarkdownGetsNoFingerprint() throws {
        try writeRaw("foreign.md", "---\ntitle: T\n---\n\n## User\n\nhi\n")
        let store = try archive()
        try ArchiveIndexer(store: store).indexFolder(folder)
        let document = try XCTUnwrap(
            store.document(withPath: folder.appendingPathComponent("foreign.md").standardizedFileURL.path)
        )
        XCTAssertEqual(document.fingerprint, "")
        XCTAssertTrue(try store.duplicateGroups().isEmpty)
    }

    func testEmptyFolderIsFine() throws {
        let store = try archive()
        let report = try ArchiveIndexer(store: store).indexFolder(folder)
        XCTAssertEqual(report.indexed, 0)
        XCTAssertEqual(report.failed.count, 0)
    }

    func testMissingFolderIsNotFatal() throws {
        let store = try archive()
        let missing = folder.appendingPathComponent("does-not-exist")
        XCTAssertEqual(try ArchiveIndexer(store: store).indexFolder(missing).indexed, 0)
    }

    // MARK: - Metadata

    func testMetadataIsReadFromFrontmatter() throws {
        try writeFile("a.md", conversation("Saved Title", turns: [Turn(role: .user, body: "x")]))
        let store = try archive()
        try ArchiveIndexer(store: store).indexFolder(folder)

        let document = try XCTUnwrap(store.document(withPath: folder.appendingPathComponent("a.md").standardizedFileURL.path))
        XCTAssertEqual(document.title, "Saved Title")
        XCTAssertEqual(document.platform, "Claude")
        XCTAssertEqual(document.model, "claude-opus-5")
    }

    func testIncompleteCaptureIsFlagged() throws {
        let partial = Conversation(
            title: "Partial", source: .claude,
            turns: [Turn(role: .user, body: "x")],
            confidence: ExtractionConfidence(score: 0.2, complete: false, strategy: .dom, warnings: ["truncated"])
        )
        try writeFile("partial.md", partial)
        let store = try archive()
        try ArchiveIndexer(store: store).indexFolder(folder)

        let document = try XCTUnwrap(store.document(withPath: folder.appendingPathComponent("partial.md").standardizedFileURL.path))
        XCTAssertTrue(document.incomplete)
    }

    /// The saver's own fingerprint must survive a round trip through disk, or
    /// dedup never matches anything.
    func testFingerprintSurvivesTheRoundTrip() throws {
        let conv = conversation("A", turns: [Turn(role: .user, body: "content")])
        try writeFile("a.md", conv)
        let store = try archive()
        try ArchiveIndexer(store: store).indexFolder(folder)

        let document = try XCTUnwrap(store.document(withPath: folder.appendingPathComponent("a.md").standardizedFileURL.path))
        XCTAssertEqual(document.fingerprint, Fingerprint.short(conv, length: 16))
        XCTAssertFalse(document.fingerprint.isEmpty)
    }

    func testContentIsTagged() throws {
        try writeFile("a.md", conversation("A", turns: [Turn(role: .assistant, body: "```swift\nlet x = 1\n```")]))
        let store = try archive()
        try ArchiveIndexer(store: store).indexFolder(folder)
        let tags = try store.database.query(
            "SELECT tag FROM tags JOIN documents ON documents.id = tags.document_id WHERE documents.path = ?",
            [.text(folder.appendingPathComponent("a.md").standardizedFileURL.path)]
        ) { $0.string(0) ?? "" }
        XCTAssertTrue(tags.contains("code"))
        XCTAssertTrue(tags.contains("swift"))
    }

    // MARK: - Platform slugs

    func testPlatformSlugRoundTrips() {
        XCTAssertEqual(ArchiveIndexer.platformSlug(from: "Claude"), "claude")
        XCTAssertEqual(ArchiveIndexer.platformSlug(from: "ChatGPT"), "chatgpt")
        XCTAssertEqual(ArchiveIndexer.platformSlug(from: "Web"), "web")
    }

    func testUnknownPlatformBecomesASlug() {
        XCTAssertEqual(ArchiveIndexer.platformSlug(from: "Some New App"), "some new app")
    }

    func testMissingPlatformIsNil() {
        XCTAssertNil(ArchiveIndexer.platformSlug(from: nil))
    }
}

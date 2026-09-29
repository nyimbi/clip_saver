import Foundation
import XCTest
@testable import Clipboard_saver

/// Tests for rendering search results.
///
/// The service puts its output on the pasteboard, so this text is the actual
/// product the user sees. It is tested as prose rather than as a data structure
/// for that reason.
final class SearchServiceTests: XCTestCase {

    private func hit(_ path: String, turn: Int, role: String = "user", snippet: String = "a <<match>> here") -> SearchHit {
        SearchHit(
            path: path,
            title: "Title",
            platform: "Claude",
            turn: turn,
            role: role,
            snippet: snippet,
            score: -1
        )
    }

    // MARK: - Rendering

    func testNoMatchesExplainsItself() {
        let result = SearchService.Result(query: "nothing", hits: [], totalMessages: 5, totalDocuments: 2, scannedFolder: nil, error: nil)
        let markdown = result.markdown()
        XCTAssertTrue(markdown.contains("No archived messages match"))
        XCTAssertTrue(markdown.contains("nothing"))
    }

    func testNoMatchesNamesTheFolderSoTheUserCanTellAnEmptyArchiveFromAWrongOne() {
        let folder = URL(fileURLWithPath: "/Users/x/Documents/Conversations")
        let result = SearchService.Result(query: "q", hits: [], totalMessages: 0, totalDocuments: 0, scannedFolder: folder, error: nil)
        XCTAssertTrue(result.markdown().contains("Conversations"))
    }

    /// "No results" means two different things — nothing indexed, or the wrong
    /// folder. Showing the index size tells them which.
    func testMatchSummaryReportsTheIndexSize() {
        let result = SearchService.Result(query: "q", hits: [hit("/a.md", turn: 0)], totalMessages: 120, totalDocuments: 7, scannedFolder: nil, error: nil)
        let markdown = result.markdown()
        XCTAssertTrue(markdown.contains("120 messages across 7 documents"))
    }

    func testMatchIsAnnouncedWithTheQuery() {
        let result = SearchService.Result(query: "actors", hits: [hit("/a.md", turn: 0)], totalMessages: 1, totalDocuments: 1, scannedFolder: nil, error: nil)
        XCTAssertTrue(result.markdown().contains("actors"))
    }

    /// The filename matters more than the title in Finder, because that is what
    /// the user will search for in a folder full of files.
    func testEachHitNamesItsFile() {
        let result = SearchService.Result(
            query: "q",
            hits: [hit("/Users/x/Documents/Swift actors.md", turn: 2)],
            totalMessages: 1, totalDocuments: 1, scannedFolder: nil, error: nil
        )
        XCTAssertTrue(result.markdown().contains("Swift actors"))
    }

    /// The turn number is what makes a hit actionable in a long conversation.
    func testEachHitReportsItsTurn() {
        let result = SearchService.Result(query: "q", hits: [hit("/a.md", turn: 41)], totalMessages: 1, totalDocuments: 1, scannedFolder: nil, error: nil)
        XCTAssertTrue(result.markdown().contains("turn 42"))
    }

    func testEachHitReportsItsRole() {
        let result = SearchService.Result(
            query: "q", hits: [hit("/a.md", turn: 0, role: "assistant")],
            totalMessages: 1, totalDocuments: 1, scannedFolder: nil, error: nil
        )
        XCTAssertTrue(result.markdown().contains("assistant"))
    }

    /// FTS5 marks matches with sentinel delimiters. Left in place they render as
    /// literal `<<` and `>>`, so they are converted to Markdown emphasis.
    func testSnippetMarkersBecomeEmphasis() {
        let result = SearchService.Result(query: "q", hits: [hit("/a.md", turn: 0)], totalMessages: 1, totalDocuments: 1, scannedFolder: nil, error: nil)
        let markdown = result.markdown()
        XCTAssertTrue(markdown.contains("**match**"))
        XCTAssertFalse(markdown.contains("<<"))
        XCTAssertFalse(markdown.contains(">>"))
    }

    /// A result set that scrolls for four screens is not a result.
    func testLongResultsAreCapped() {
        let hits = (0..<30).map { hit("/\(0).md", turn: $0) }
        let result = SearchService.Result(query: "q", hits: hits, totalMessages: 30, totalDocuments: 1, scannedFolder: nil, error: nil)
        let markdown = result.markdown(limit: 5)
        XCTAssertTrue(markdown.contains("25 more not shown"))
        XCTAssertEqual(markdown.components(separatedBy: "\n").filter { $0.hasPrefix("1. ") }.count, 1)
    }

    func testSingleMatchIsNotPluralised() {
        let result = SearchService.Result(query: "q", hits: [hit("/a.md", turn: 0)], totalMessages: 1, totalDocuments: 1, scannedFolder: nil, error: nil)
        XCTAssertTrue(result.markdown().contains("**1** match for"))
    }

    func testSeveralMatchesArePluralised() {
        let result = SearchService.Result(
            query: "q", hits: [hit("/a.md", turn: 0), hit("/b.md", turn: 0)],
            totalMessages: 2, totalDocuments: 2, scannedFolder: nil, error: nil
        )
        XCTAssertTrue(result.markdown().contains("matches for"))
    }

    /// An error is reported as an error. Silently returning "no results" for a
    /// broken index is how a user concludes their archive is empty.
    func testErrorIsSurfacedNotSwallowed() {
        let result = SearchService.Result(
            query: "q", hits: [], totalMessages: 0, totalDocuments: 0,
            scannedFolder: nil, error: "database is locked"
        )
        let markdown = result.markdown()
        XCTAssertTrue(markdown.contains("failed"))
        XCTAssertTrue(markdown.contains("database is locked"))
        XCTAssertFalse(result.isEmpty)
    }

    func testResultIsNotEmptyWhenThereAreHits() {
        let result = SearchService.Result(query: "q", hits: [hit("/a.md", turn: 0)], totalMessages: 1, totalDocuments: 1, scannedFolder: nil, error: nil)
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Folders

    /// Creating a folder the user never asked for would be worse than finding
    /// nothing, so the default is a path that may not exist and is simply
    /// skipped.
    func testDefaultFolderIsUnderDocuments() {
        let folder = try? XCTUnwrap(SearchService.folders(fromDefaults: isolatedDefaults()).first)
        XCTAssertEqual(folder?.lastPathComponent, "Conversations")
    }

    func testConfiguredFoldersTakePrecedence() {
        let defaults = isolatedDefaults()
        defaults.set(["/tmp/one", "/tmp/two"], forKey: "archiveFolders")
        XCTAssertEqual(
            SearchService.folders(fromDefaults: defaults).map(\.path),
            ["/tmp/one", "/tmp/two"]
        )
    }

    func testEmptyConfigurationFallsBackToTheDefault() {
        let defaults = isolatedDefaults()
        defaults.set([String](), forKey: "archiveFolders")
        XCTAssertEqual(SearchService.folders(fromDefaults: defaults).count, 1)
    }

    /// `UserDefaults.standard` in a test process points at the real app's
    /// defaults, so a test that wrote to it would change the user's settings.
    private func isolatedDefaults() -> UserDefaults {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }
}

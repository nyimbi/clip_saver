import AppKit
import XCTest
@testable import Clipboard_saver

/// End-to-end coverage of the save pipeline: pasteboard in, files on disk out.
final class SavePipelineTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-saver-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    private func pasteboard(plain: String? = nil, html: String? = nil) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        let item = NSPasteboardItem()
        if let plain { item.setString(plain, forType: .string) }
        if let html { item.setString(html, forType: .html) }
        board.writeObjects([item])
        return board
    }

    private func contents() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .sorted()
    }

    // MARK: - Writing

    func testMarkdownIsWrittenWithTheHeadingAsItsName() throws {
        let board = pasteboard(html: "<h1>Project Notes</h1><p>Body.</p>")
        guard case .written(let urls) = AppDelegate().save(pasteboard: board, into: [directory]) else {
            return XCTFail("save failed")
        }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Project Notes.md"])
        let text = try String(contentsOf: urls[0], encoding: .utf8)
        XCTAssertEqual(text, "# Project Notes\n\nBody.")
    }

    func testPlainProseIsWrittenAsATextFile() throws {
        let board = pasteboard(plain: "Just a sentence.")
        guard case .written(let urls) = AppDelegate().save(pasteboard: board, into: [directory]) else {
            return XCTFail("save failed")
        }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Just a sentence.txt"])
    }

    func testRepeatedSavesDoNotOverwrite() throws {
        let board = pasteboard(html: "<h1>Notes</h1>")
        let delegate = AppDelegate()
        for expected in ["Notes.md", "Notes (1).md", "Notes (2).md"] {
            guard case .written(let urls) = delegate.save(pasteboard: board, into: [directory]) else {
                return XCTFail("save failed")
            }
            XCTAssertEqual(urls.map(\.lastPathComponent), [expected])
        }
        XCTAssertEqual(try contents(), ["Notes (1).md", "Notes (2).md", "Notes.md"])
    }

    func testOneFilePerDestinationFolder() throws {
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-saver-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }

        let board = pasteboard(html: "<h1>Shared</h1>")
        guard case .written(let urls) = AppDelegate().save(pasteboard: board, into: [directory, other]) else {
            return XCTFail("save failed")
        }
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)), ["Shared.md"])
    }

    // MARK: - Failures

    func testEmptyPasteboardIsReported() {
        let board = NSPasteboard.withUniqueName()
        guard case .failed(let message) = AppDelegate().save(pasteboard: board, into: [directory]) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(message.contains("no text"), message)
    }

    func testMissingDirectoryIsReportedNotCrashed() {
        let missing = directory.appendingPathComponent("does-not-exist")
        let board = pasteboard(html: "<h1>Notes</h1>")
        guard case .failed = AppDelegate().save(pasteboard: board, into: [missing]) else {
            return XCTFail("expected failure")
        }
    }

    func testAFilePassedAsADirectoryIsReported() throws {
        let file = directory.appendingPathComponent("a-file.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let board = pasteboard(html: "<h1>Notes</h1>")
        guard case .failed = AppDelegate().save(pasteboard: board, into: [file]) else {
            return XCTFail("expected failure")
        }
    }

    // MARK: - Destination resolution

    /// Right-clicking a file writes into its parent, so the new file lands
    /// alongside the document.
    func testSelectedFileResolvesToItsParentFolder() throws {
        let file = directory.appendingPathComponent("existing.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let board = NSPasteboard.withUniqueName()
        board.writeObjects([file as NSURL])

        let folders = AppDelegate().destinationFolders(from: board)
        XCTAssertEqual(folders.map(\.standardizedFileURL.path), [directory.standardizedFileURL.path])
    }

    func testSelectedFolderResolvesToItself() throws {
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let board = NSPasteboard.withUniqueName()
        board.writeObjects([nested as NSURL])

        let folders = AppDelegate().destinationFolders(from: board)
        XCTAssertEqual(folders.map(\.standardizedFileURL.path), [nested.standardizedFileURL.path])
    }

    func testAFolderAndItsChildResolveToOneDestination() throws {
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let board = NSPasteboard.withUniqueName()
        board.writeObjects([nested as NSURL, directory as NSURL])

        let folders = AppDelegate().destinationFolders(from: board)
        XCTAssertEqual(folders.count, 2, "a folder and its parent are distinct destinations")
    }

    func testEmptySelectionResolvesToNoDestinations() {
        let board = NSPasteboard.withUniqueName()
        XCTAssertTrue(AppDelegate().destinationFolders(from: board).isEmpty)
    }

    // MARK: - Destination resolution with the background fallback

    /// A background right-click is the flow the utility is built around: no
    /// selection, so the front Finder window supplies the folder.
    func testBackgroundClickFallsBackToTheFrontWindowFolder() {
        let board = NSPasteboard.withUniqueName()
        let front = URL(fileURLWithPath: "/tmp/front-window", isDirectory: true)
        let folders = AppDelegate().resolveDestinations(from: board, frontWindowFolder: front)
        XCTAssertEqual(folders.map(\.path), [front.path])
    }

    /// When something is selected, the selection wins over the front window.
    func testSelectionWinsOverTheFrontWindowFolder() throws {
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let board = NSPasteboard.withUniqueName()
        board.writeObjects([nested as NSURL])

        let front = directory.appendingPathComponent("elsewhere", isDirectory: true)
        let folders = AppDelegate().resolveDestinations(from: board, frontWindowFolder: front)
        XCTAssertEqual(folders.map(\.standardizedFileURL.path), [nested.standardizedFileURL.path])
    }

    // MARK: - Legacy pasteboard path list

    /// The `NSFilenamesPboardType` acquisition cannot be synthesised, so the
    /// parsing is separated from it and tested here instead.
    func testLegacyPathListIsParsed() {
        let urls = AppDelegate.urls(fromLegacyPathList: ["/tmp/a.md", "/tmp/b.md"])
        XCTAssertEqual(urls.map(\.path), ["/tmp/a.md", "/tmp/b.md"])
    }

    func testLegacyPathListIgnoresNonStringsAndBlanks() {
        XCTAssertTrue(AppDelegate.urls(fromLegacyPathList: [42, "", "  ", ["nested"]]).isEmpty)
        let mixed = AppDelegate.urls(fromLegacyPathList: [7, "/tmp/ok.md", ""])
        XCTAssertEqual(mixed.map(\.path), ["/tmp/ok.md"])
    }

    func testLegacyPathListAcceptsAnything() {
        XCTAssertTrue(AppDelegate.urls(fromLegacyPathList: nil).isEmpty)
        XCTAssertTrue(AppDelegate.urls(fromLegacyPathList: "a string").isEmpty)
        XCTAssertTrue(AppDelegate.urls(fromLegacyPathList: ["a": 1]).isEmpty)
    }

    /// A file and its parent folder must resolve to one destination, not two.
    func testDuplicateDestinationsAreCollapsed() throws {
        let file = directory.appendingPathComponent("one.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let folders = AppDelegate.folders(for: [file, directory, file])
        XCTAssertEqual(folders.map(\.standardizedFileURL.path), [directory.standardizedFileURL.path])
    }

    func testNoSelectionAndNoWindowResolvesToNothing() {
        let board = NSPasteboard.withUniqueName()
        XCTAssertTrue(AppDelegate().resolveDestinations(from: board, frontWindowFolder: nil).isEmpty)
    }
}

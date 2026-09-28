import AppKit
import XCTest
@testable import Clipboard_saver

/// Covers the interactive path: the filename the user confirms in the save
/// panel is what gets written, and every path component stays legal.
final class ChosenFilenameTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-saver-chosen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    private var markdown: (text: String, source: MarkdownSource) {
        ("# Project Notes\n\nBody.", .html)
    }

    private func written() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: - The chosen name wins

    func testConfirmedNameIsUsedVerbatim() throws {
        let outcome = AppDelegate().save(export: markdown, into: [directory], name: "My Own Name.md")
        guard case .written(let urls) = outcome else { return XCTFail("save failed") }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["My Own Name.md"])
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "# Project Notes\n\nBody.")
    }

    /// The panel is where the user confirms a replacement, so the first
    /// destination takes the name exactly as given.
    func testConfirmedNameMayReplaceAnExistingFile() throws {
        try "old".write(to: directory.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8)
        _ = AppDelegate().save(export: markdown, into: [directory], name: "Notes.md")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("Notes.md"), encoding: .utf8),
                       "# Project Notes\n\nBody.")
    }

    /// Additional destinations are not shown in the panel, so they must never
    /// be overwritten silently.
    func testExtraDestinationsAreCollisionResolved() throws {
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-saver-chosen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }

        try "existing".write(to: other.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8)

        guard case .written(let urls) = AppDelegate().save(
            export: markdown, into: [directory, other], name: "Notes.md"
        ) else { return XCTFail("save failed") }

        XCTAssertEqual(urls.map(\.lastPathComponent), ["Notes.md", "Notes (1).md"])
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("Notes.md"), encoding: .utf8),
                       "existing")
    }

    func testFailureIsReportedWhenTheDirectoryIsMissing() {
        let missing = directory.appendingPathComponent("nope")
        guard case .failed = AppDelegate().save(export: markdown, into: [missing], name: "Notes.md") else {
            return XCTFail("expected failure")
        }
    }

    // MARK: - Sanitising what the user typed

    /// The name field accepts anything, including a path separator, so the
    /// typed value is sanitised before it reaches the file system.
    func testTypedPathSeparatorsAreRemoved() {
        XCTAssertEqual("a/b:c*d?".sanitizedForTypedFilename, "a b c d")
    }

    func testTypedTrailingSeparatorsAreRemoved() {
        XCTAssertEqual("Report.".sanitizedForTypedFilename, "Report")
        XCTAssertEqual("Report  ".sanitizedForTypedFilename, "Report")
    }

    func testTypedLeadingDotIsRemoved() {
        XCTAssertEqual(".hidden".sanitizedForTypedFilename, "hidden")
    }

    func testTypedNameIsNotShortenedToTheReadabilityLimit() {
        // 120 characters: well past the 80 used for generated names, but a
        // name a person deliberately typed must survive intact.
        let typed = String(repeating: "a", count: 120)
        XCTAssertEqual(typed.sanitizedForTypedFilename.count, 120)
    }

    func testTypedNameStillRespectsTheFileSystemLimit() {
        let typed = String(repeating: "a", count: 400)
        XCTAssertLessThanOrEqual(typed.sanitizedForTypedFilename.utf8.count, FilenameGenerator.byteLimit)
    }

    func testGeneratedNamesStillUseTheReadabilityLimit() {
        let generated = String(repeating: "word ", count: 40)
        XCTAssertLessThanOrEqual(
            generated.sanitizedForFilename.count,
            FilenameGenerator.maximumLength
        )
    }
}

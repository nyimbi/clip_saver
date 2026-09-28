import XCTest
@testable import Clipboard_saver

final class FilenameGeneratorTests: XCTestCase {

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-saver-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Title

    func testHeadingIsPreferred() {
        XCTAssertEqual(
            FilenameGenerator.title(from: "# Understanding macOS Pasteboards\n\nBody."),
            "Understanding macOS Pasteboards"
        )
    }

    func testTrailingClosingHashesAreStripped() {
        XCTAssertEqual(FilenameGenerator.title(from: "## Notes ##\nBody"), "Notes")
    }

    func testFallsBackToFirstNonEmptyLine() {
        XCTAssertEqual(
            FilenameGenerator.title(from: "\n\n   \nHow do I debounce a search box?\n\nBody."),
            "How do I debounce a search box?"
        )
    }

    func testSetextHeadingIsRecognised() {
        XCTAssertEqual(FilenameGenerator.title(from: "Release Notes\n==========\nBody."), "Release Notes")
    }

    func testWhitespaceOnlyContentHasNoTitle() {
        XCTAssertEqual(FilenameGenerator.title(from: "   \n  \n\t"), "")
    }

    // MARK: - Sanitisation

    func testIllegalCharactersAreRemoved() {
        let name = FilenameGenerator.make(
            from: "# Research/ Notes: Q&A *final* <draft>",
            fileExtension: "md",
            in: nil
        )
        for character in ["/", ":", "*", "?", "<", ">", "|", "\\"] {
            XCTAssertFalse(name.contains(character), "\(character) survived in \(name)")
        }
        XCTAssertTrue(name.hasSuffix(".md"))
    }

    func testNewlinesAndControlCharactersDoNotSurvive() {
        let name = FilenameGenerator.make(from: "a\nb\tc", fileExtension: "md", in: nil)
        XCTAssertFalse(name.contains("\n"))
        XCTAssertFalse(name.contains("\t"))
    }

    func testLeadingDotIsRemoved() {
        XCTAssertEqual(FilenameGenerator.make(from: "...hidden", fileExtension: "md", in: nil), "hidden.md")
    }

    func testReservedNameIsEscaped() {
        let name = FilenameGenerator.make(from: "con", fileExtension: "md", in: nil)
        XCTAssertTrue(name.hasPrefix("_"), name)
    }

    /// Regression: truncation used to cut mid-word and leave a trailing space,
    /// producing `...and .md`.
    func testLongTitlesAreTruncatedOnAWordBoundaryWithoutTrailingSpace() {
        let title = "a very long single line that just keeps going and going and going and going and going and going beyond eighty characters"
        let name = FilenameGenerator.make(from: title, fileExtension: "md", in: nil)
        let stem = String(name.dropLast(".md".count))
        XCTAssertLessThanOrEqual(stem.count, FilenameGenerator.maximumLength)
        XCTAssertFalse(stem.hasSuffix(" "), stem)
        XCTAssertFalse(stem.hasSuffix("."), stem)
        XCTAssertFalse(stem.hasSuffix(","), stem)
    }

    func testUnicodeTitlesArePreserved() {
        XCTAssertEqual(
            FilenameGenerator.make(from: "# 多字节 标题 你好", fileExtension: "md", in: nil),
            "多字节 标题 你好.md"
        )
    }

    func testEmptyContentFallsBackToATimestamp() {
        let name = FilenameGenerator.make(from: "   \n  ", fileExtension: "md", in: nil)
        XCTAssertTrue(name.hasPrefix("clipboard_save_"), name)
        XCTAssertTrue(name.hasSuffix(".md"), name)
    }

    // MARK: - Collisions

    func testCollisionAppendsASequentialSuffix() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = FilenameGenerator.make(from: "# Notes", fileExtension: "md", in: directory)
        XCTAssertEqual(first, "Notes.md")
        try "x".write(to: directory.appendingPathComponent(first), atomically: true, encoding: .utf8)

        let second = FilenameGenerator.make(from: "# Notes", fileExtension: "md", in: directory)
        XCTAssertEqual(second, "Notes (1).md")
        try "x".write(to: directory.appendingPathComponent(second), atomically: true, encoding: .utf8)

        XCTAssertEqual(FilenameGenerator.make(from: "# Notes", fileExtension: "md", in: directory), "Notes (2).md")
    }

    func testCollisionSuffixIsInsertedBeforeTheExtension() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "x".write(to: directory.appendingPathComponent("Report.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            FilenameGenerator.make(from: "# Report", fileExtension: "md", in: directory),
            "Report (1).md"
        )
    }

    func testNoDirectoryMeansNoCollisionCheck() {
        XCTAssertEqual(FilenameGenerator.make(from: "# Notes", fileExtension: "md", in: nil), "Notes.md")
    }
}

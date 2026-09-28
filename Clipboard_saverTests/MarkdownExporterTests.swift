import AppKit
import XCTest
@testable import Clipboard_saver

final class MarkdownExporterTests: XCTestCase {

    private func pasteboard(
        plain: String? = nil,
        html: String? = nil,
        rtf: Data? = nil
    ) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        var items: [NSPasteboardItem] = []
        let item = NSPasteboardItem()
        if let plain { item.setString(plain, forType: .string) }
        if let html { item.setString(html, forType: .html) }
        if let rtf { item.setData(rtf, forType: .rtf) }
        items.append(item)
        board.writeObjects(items)
        return board
    }

    // MARK: - Source selection

    /// A plain-text "Copy" from a Markdown-aware source is already Markdown
    /// and must be passed through untouched, even when HTML is also present.
    func testExistingMarkdownPlainTextWins() {
        let board = pasteboard(plain: "# Title\n\n- item", html: "<h1>Title</h1><ul><li>item</li></ul>")
        guard let export = MarkdownExporter.export(from: board) else { return XCTFail("no export") }
        XCTAssertEqual(export.source, .markdown)
        XCTAssertEqual(export.text, "# Title\n\n- item")
        XCTAssertEqual(export.source.fileExtension, "md")
    }

    func testHTMLIsConvertedWhenPlainTextIsNotMarkdown() {
        let board = pasteboard(plain: "Title", html: "<h1>Title</h1><ul><li>a</li><li>b</li></ul>")
        guard let export = MarkdownExporter.export(from: board) else { return XCTFail("no export") }
        XCTAssertEqual(export.source, .html)
        XCTAssertEqual(export.text, "# Title\n\n- a\n- b")
        XCTAssertEqual(export.source.fileExtension, "md")
    }

    func testPlainProseFallsBackToATextFile() {
        let board = pasteboard(plain: "Just a sentence with no Markdown in it.")
        guard let export = MarkdownExporter.export(from: board) else { return XCTFail("no export") }
        XCTAssertEqual(export.source, .plain)
        XCTAssertEqual(export.source.fileExtension, "txt")
    }

    func testRTFIsUsedWhenThereIsNoHTML() throws {
        // Non-Markdown prose, so the plain representation does not win first.
        let attributed = NSAttributedString(string: "Plain sentence.\nAnother sentence.")
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let board = pasteboard(rtf: data)
        guard let export = MarkdownExporter.export(from: board) else { return XCTFail("no export") }
        XCTAssertEqual(export.source, .rtf)
        XCTAssertEqual(export.source.fileExtension, "md")
    }

    func testEmptyPasteboardYieldsNothing() {
        let board = NSPasteboard.withUniqueName()
        XCTAssertNil(MarkdownExporter.export(from: board))
    }

    func testWhitespaceOnlyPasteboardYieldsNothing() {
        XCTAssertNil(MarkdownExporter.export(from: pasteboard(plain: "   \n\t  ")))
    }

    // MARK: - Markdown detection

    /// Regression: the old rule needed three list lines, or a heading *and* a
    /// list. A heading followed by prose was therefore saved as `.txt`, which
    /// is the single most common shape of a ChatGPT answer.
    func testHeadingFollowedByProseIsMarkdown() {
        XCTAssertTrue(MarkdownExporter.looksLikeMarkdown("# Title\n\nProse paragraph.\n\nMore prose."))
    }

    func testSingleListItemIsMarkdown() {
        XCTAssertTrue(MarkdownExporter.looksLikeMarkdown("- one\n- two"))
    }

    func testCommonMarkdownConstructs() {
        let cases: [(String, Bool)] = [
            ("# Heading", true),
            ("###### Deep heading", true),
            ("## Heading ##", true),
            ("- bullet", true),
            ("* bullet", true),
            ("+ bullet", true),
            ("1. ordered", true),
            ("1) ordered", true),
            ("> quoted", true),
            ("```\ncode\n```", true),
            ("| a | b |\n| --- | --- |", true),
            ("---", true),
            ("Title\n=====", true),
            ("    indented code block", false),
            ("Just a sentence.", false),
            ("Issue #123 is open", false),
            ("e-mail me at a@b.test", false),
            ("", false),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(
                MarkdownExporter.looksLikeMarkdown(text), expected,
                "wrong verdict for \(text.debugDescription)"
            )
        }
    }
}

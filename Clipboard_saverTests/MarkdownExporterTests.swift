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

    /// End-to-end over a pasteboard shaped like the one a browser leaves
    /// behind, exercising representation choice, HTML conversion, escaping and
    /// every construct fixed in the converter work: a list item followed by a
    /// nested list and then trailing text, sub/superscript, and an ordered list
    /// with a start attribute.
    func testRealisticBrowserHTMLConvertsCompletely() throws {
        let html = """
        <meta charset='utf-8'><h2 style="font-weight: bold;">Understanding macOS Pasteboards</h2>\
        <p>Here is <b>what happened</b> during the <i>test</i>.</p>\
        <ol><li>First step</li><li>Second step</li></ol>\
        <ul><li>bullet one</li><li>bullet two</li></ul>\
        <blockquote>Quoted wisdom.</blockquote>\
        <pre>let x = 1
        print(x)</pre>\
        <table><tr><th>Name</th><th>Role</th></tr><tr><td>Alice</td><td>Engineer</td></tr></table>\
        <p>See <a href="https://example.com/docs">the docs</a>.</p>\
        <p>Formula: H<sub>2</sub>O, E=mc<sup>2</sup></p>\
        <ul><li>Outer<ul><li>Inner</li></ul>tail text</li></ul>\
        <ol start='3'><li>third</li><li>fourth</li></ol>
        """
        let board = pasteboard(
            plain: "Understanding macOS Pasteboards\nHere is what happened during the test.",
            html: html
        )
        let export = try XCTUnwrap(MarkdownExporter.export(from: board))
        XCTAssertEqual(export.source, .html)

        let expected = """
        ## Understanding macOS Pasteboards

        Here is **what happened** during the *test*.

        1. First step
        2. Second step

        - bullet one
        - bullet two

        > Quoted wisdom.

        ```
        let x = 1
        print(x)
        ```

        | Name | Role |
        | --- | --- |
        | Alice | Engineer |

        See [the docs](https://example.com/docs).

        Formula: H<sub>2</sub>O, E=mc<sup>2</sup>

        - Outer
          - Inner

          tail text

        3. third
        4. fourth
        """
        XCTAssertEqual(export.text, expected)
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

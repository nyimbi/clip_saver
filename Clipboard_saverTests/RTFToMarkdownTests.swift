import AppKit
import XCTest
@testable import Clipboard_saver

/// The RTF fallback is used when a pasteboard carries RTF but no HTML.
///
/// RTF has no tag tree, so structure comes from the style run. The rule that
/// makes it usable is that the *modal* font size is body text: the previous
/// implementation mapped 11...15.5 points to heading level 5, and the system
/// body size is 13, so every paragraph came out as `##### text`.
final class RTFToMarkdownTests: XCTestCase {

    private let body = NSFont.systemFont(ofSize: 13)
    private let title = NSFont.boldSystemFont(ofSize: 24)
    private let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func attributed(_ blocks: [(String, NSFont)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(NSAttributedString(string: block.0, attributes: [.font: block.1]))
        }
        return result
    }

    private func convert(_ blocks: [(String, NSFont)], file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let markdown = RTFToMarkdown.convert(attributed(blocks)) else {
            XCTFail("expected Markdown, got nil", file: file, line: line)
            return ""
        }
        return markdown
    }

    func testBodyProseIsNotAHeading() {
        XCTAssertEqual(
            convert([("An ordinary paragraph of prose.", body)]),
            "An ordinary paragraph of prose."
        )
    }

    func testLargeBoldTextIsAHeading() {
        XCTAssertEqual(
            convert([("Report Title", title), ("Body text.", body)]),
            "# Report Title\n\nBody text."
        )
    }

    func testMonospacedTextBecomesACodeFence() {
        XCTAssertEqual(
            convert([("Intro:", body), ("let x = 1", mono), ("print(x)", mono)]),
            "Intro:\n\n```\nlet x = 1\nprint(x)\n```"
        )
    }

    /// `NSAttributedString` pads list bullets with tabs. The marker therefore
    /// has to be found after the leading whitespace, not at position zero.
    func testTabsAheadOfBulletsDoNotDefeatTheListDetector() {
        XCTAssertEqual(
            convert([("Header", title), ("\t• Alpha", body), ("\t• Beta", body)]),
            "# Header\n\n- Alpha\n- Beta"
        )
    }

    func testOrderedBulletsKeepTheirNumbering() {
        XCTAssertEqual(
            convert([("\t1\tFirst", body), ("\t2\tSecond", body)]),
            "1. First\n2. Second"
        )
    }

    func testIndentedParagraphsBecomeBlockQuotes() {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 36
        style.headIndent = 36

        let quoted = NSMutableAttributedString(
            string: "Quoted line",
            attributes: [.font: body, .paragraphStyle: style]
        )
        XCTAssertEqual(RTFToMarkdown.convert(quoted), "> Quoted line")
    }

    /// Column count is the most common cell count in the block. The old
    /// implementation searched divisors of the total, which cannot tell a 2x3
    /// table from a 3x2 one.
    func testTabDelimitedBlockBecomesATable() {
        XCTAssertEqual(
            convert([
                ("Name\tRole", body), ("Alice\tEngineer", body), ("Bob\tDesigner", body),
            ]),
            "| Name | Role |\n| --- | --- |\n| Alice | Engineer |\n| Bob | Designer |"
        )
    }

    func testThreeColumnTableIsNotTransposed() {
        XCTAssertEqual(
            convert([
                ("a\tb\tc", body), ("1\t2\t3", body), ("4\t5\t6", body),
            ]),
            "| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |"
        )
    }

    func testRaggedTableIsPadded() {
        XCTAssertEqual(
            convert([("a\tb", body), ("1\t", body)]),
            "| a | b |\n| --- | --- |\n| 1 |  |"
        )
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(RTFToMarkdown.convert(NSAttributedString(string: "   ")))
    }
}

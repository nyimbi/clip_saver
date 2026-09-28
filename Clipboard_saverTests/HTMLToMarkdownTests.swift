import XCTest
@testable import Clipboard_saver

/// Structure preservation for the HTML path.
///
/// Every test here corresponds to a real regression: the previous converter
/// round-tripped HTML through `NSAttributedString` and re-derived structure
/// from font metrics, which turned paragraphs into level-5 headings and list
/// items into `"\t•\tItem"`.
final class HTMLToMarkdownTests: XCTestCase {

    private func convert(_ html: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let markdown = HTMLToMarkdown.convert(html) else {
            XCTFail("expected Markdown, got nil", file: file, line: line)
            return ""
        }
        return markdown
    }

    // MARK: - Headings and paragraphs

    func testHeadingsKeepTheirLevel() {
        XCTAssertEqual(
            convert("<h1>One</h1><h2>Two</h2><h3>Three</h3><h4>Four</h4><h5>Five</h5><h6>Six</h6>"),
            "# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six"
        )
    }

    /// Regression: the system body size is 13pt and the old thresholds mapped
    /// anything between 11 and 15.5pt to heading level 5, so every paragraph of
    /// prose came out as `##### text`.
    func testParagraphIsNeverAHeading() {
        let body = "Just an ordinary sentence of prose that is not a heading."
        XCTAssertEqual(convert("<p>\(body)</p>"), body)
    }

    func testConsecutiveParagraphsAreSeparatedByABlankLine() {
        XCTAssertEqual(
            convert("<p>First.</p><p>Second.</p>"),
            "First.\n\nSecond."
        )
    }

    func testDeeplyNestedSectioningElements() {
        XCTAssertEqual(
            convert("<div><div><p>Deep text.</p></div></div>"),
            "Deep text."
        )
    }

    // MARK: - Inline formatting

    func testInlineEmphasis() {
        XCTAssertEqual(
            convert("<p>Plain <b>bold</b> and <i>italic</i> and <code>mono()</code>.</p>"),
            "Plain **bold** and *italic* and `mono()`."
        )
    }

    func testWhitespaceAroundInlineElementsIsPreserved() {
        XCTAssertEqual(convert("<p>Hello <b>world</b> ok</p>"), "Hello **world** ok")
    }

    func testLinkKeepsItsTarget() {
        XCTAssertEqual(
            convert(#"<p>See <a href="https://example.com/x">the docs</a>.</p>"#),
            "See [the docs](https://example.com/x)."
        )
    }

    func testImageBecomesMarkdownImage() {
        XCTAssertEqual(
            convert(#"<p><img src="https://x.test/a.png" alt="diagram"></p>"#),
            "![diagram](https://x.test/a.png)"
        )
    }

    /// Safari emits inline styles where other browsers emit semantic tags.
    func testSafariStyleSpans() {
        XCTAssertEqual(
            convert(#"<p><span style="font-weight: 700">Bold</span> and <span style="font-style: italic">Italic</span></p>"#),
            "**Bold** and *Italic*"
        )
    }

    func testStrikethrough() {
        XCTAssertEqual(convert("<p><del>gone</del></p>"), "~~gone~~")
    }

    func testJavaScriptLinksAreNotEmitted() {
        XCTAssertEqual(convert(#"<p><a href="javascript:alert(1)">click</a></p>"#), "click")
    }

    // MARK: - Lists

    func testUnorderedListIsTight() {
        XCTAssertEqual(convert("<ul><li>Alpha</li><li>Beta</li></ul>"), "- Alpha\n- Beta")
    }

    func testOrderedListKeepsItsNumbering() {
        XCTAssertEqual(convert("<ol><li>One</li><li>Two</li><li>Three</li></ol>"), "1. One\n2. Two\n3. Three")
    }

    func testNestedListIsIndented() {
        XCTAssertEqual(
            convert("<ul><li>Parent<ul><li>Child</li></ul></li><li>Other</li></ul>"),
            "- Parent\n  - Child\n- Other"
        )
    }

    func testUnclosedListItemsStillProduceOneItemEach() {
        XCTAssertEqual(convert("<ul><li>one<li>two<li>three</ul>"), "- one\n- two\n- three")
    }

    func testListItemWithTwoParagraphs() {
        XCTAssertEqual(
            convert("<ul><li><p>First para.</p><p>Second para.</p></li></ul>"),
            "- First para.\n\n  Second para."
        )
    }

    func testTaskListCheckboxes() {
        XCTAssertEqual(
            convert(#"<ul><li><input type="checkbox" checked> Done</li><li><input type="checkbox"> Todo</li></ul>"#),
            "- [x] Done\n- [ ] Todo"
        )
    }

    /// An `<ol>` immediately followed by a `<ul>` is two lists. Without a
    /// blank line the second one is indistinguishable from a continuation.
    func testOrderedThenUnorderedListIsNotFused() {
        XCTAssertEqual(
            convert("<ol><li>One</li><li>Two</li></ol><ul><li>Alpha</li><li>Beta</li></ul>"),
            "1. One\n2. Two\n\n- Alpha\n- Beta"
        )
    }

    func testTwoUnorderedListsInARowAreNotFused() {
        XCTAssertEqual(
            convert("<ul><li>Alpha</li></ul><ul><li>Beta</li></ul>"),
            "- Alpha\n\n- Beta"
        )
    }

    /// A nested list continues its parent, so it stays tight.
    func testNestedListStaysTightAgainstItsParent() {
        XCTAssertEqual(
            convert("<ul><li>Parent<ul><li>Child</li></ul></li></ul>"),
            "- Parent\n  - Child"
        )
    }

    func testListSeparatedByParagraphIsNotTight() {
        XCTAssertEqual(
            convert("<ul><li>Alpha</li></ul><p>Between.</p><ul><li>Beta</li></ul>"),
            "- Alpha\n\nBetween.\n\n- Beta"
        )
    }

    // MARK: - Code

    func testPreformattedBlockBecomesFence() {
        XCTAssertEqual(
            convert("<p>Intro:</p><pre><code>let x = 1\nprint(x)</code></pre>"),
            "Intro:\n\n```\nlet x = 1\nprint(x)\n```"
        )
    }

    func testFenceIsWidenedWhenContentContainsBackticks() {
        XCTAssertEqual(
            convert("<pre><code>let s = \"```\"\ndone()</code></pre>"),
            "````\nlet s = \"```\"\ndone()\n````"
        )
    }

    func testLanguageClassBecomesFenceInfo() {
        XCTAssertEqual(
            convert(#"<pre><code class="language-swift">let x = 1</code></pre>"#),
            "```swift\nlet x = 1\n```"
        )
    }

    func testCodeContentIsNotEscaped() {
        XCTAssertEqual(convert("<pre><code>a * b _ c [d]</code></pre>"), "```\na * b _ c [d]\n```")
    }

    // MARK: - Quotes and rules

    func testBlockquote() {
        XCTAssertEqual(convert("<blockquote><p>Quoted.</p></blockquote>"), "> Quoted.")
    }

    func testBlockquoteContainingAList() {
        XCTAssertEqual(
            convert("<blockquote><p>Points:</p><ul><li>one</li><li>two</li></ul></blockquote>"),
            "> Points:\n>\n> - one\n> - two"
        )
    }

    func testBlockquoteMarkersAreNotDoubleEscaped() {
        XCTAssertEqual(convert("<blockquote><p>Quoted.</p></blockquote>"), "> Quoted.")
    }

    func testThematicBreak() {
        XCTAssertEqual(convert("<p>Before</p><hr><p>After</p>"), "Before\n\n---\n\nAfter")
    }

    func testLineBreak() {
        XCTAssertEqual(convert("<p>After<br>continued</p>"), "After\\\ncontinued")
    }

    // MARK: - Tables

    func testTableWithHeaderRow() {
        XCTAssertEqual(
            convert("<table><thead><tr><th>Name</th><th>Role</th></tr></thead>"
                + "<tbody><tr><td>Alice</td><td>Engineer</td></tr></tbody></table>"),
            "| Name | Role |\n| --- | --- |\n| Alice | Engineer |"
        )
    }

    func testRaggedTableIsPadded() {
        XCTAssertEqual(
            convert("<table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table>"),
            "| a | b |\n| --- | --- |\n| c |  |"
        )
    }

    func testPipeInsideCellIsEscaped() {
        XCTAssertEqual(
            convert("<table><tr><td>a|b</td><td>c</td></tr></table>"),
            "| a\\|b | c |\n| --- | --- |"
        )
    }

    /// Regression: the old code searched divisors of the total cell count,
    /// which cannot distinguish a 2x3 table from a 3x2 one and in practice
    /// emitted no table at all.
    func testTwoByThreeTableIsNotTransposed() {
        XCTAssertEqual(
            convert("<table><tr><td>h1</td><td>h2</td></tr><tr><td>a</td><td>b</td></tr>"
                + "<tr><td>c</td><td>d</td></tr></table>"),
            "| h1 | h2 |\n| --- | --- |\n| a | b |\n| c | d |"
        )
    }

    // MARK: - Robustness

    func testScriptAndStyleContentIsDiscarded() {
        XCTAssertEqual(
            convert("<style>p{color:red}</style><script>alert(1)</script><p>visible</p>"),
            "visible"
        )
    }

    func testEntitiesAndUnicode() {
        XCTAssertEqual(
            convert("<p>Caf&eacute; &amp; cr&#232;me &mdash; 25&nbsp;&euro;</p>"),
            "Café & crème — 25 €"
        )
    }

    func testNonBreakingSpaceInsideCodeBecomesASpace() {
        XCTAssertEqual(convert("<pre><code>a&nbsp;&nbsp;b</code></pre>"), "```\na  b\n```")
    }

    func testCommentsAreDiscarded() {
        XCTAssertEqual(convert("<p>a<!-- hidden -->b</p>"), "ab")
    }

    func testEmptyDocumentReturnsNil() {
        XCTAssertNil(HTMLToMarkdown.convert("<html><body></body></html>"))
        XCTAssertNil(HTMLToMarkdown.convert(""))
    }

    func testUnterminatedTagDoesNotHang() {
        XCTAssertNotNil(HTMLToMarkdown.convert("<p>text <strong>bold"))
    }

    // MARK: - Malformed and hostile input

    /// Regression: a pasteboard holding tens of thousands of unclosed tags
    /// segfaulted the process. `Element` is recursive, so a deeply nested
    /// document is a deeply nested value, and releasing it overflows the
    /// stack. The parser now caps nesting at `maximumDepth`.
    func testDeeplyNestedUnclosedTagsDoNotCrash() {
        let html = String(repeating: "<div>", count: 200_000) + "x"
        XCTAssertNotNil(HTMLToMarkdown.convert(html))
    }

    func testDeeplyNestedBalancedTagsDoNotCrash() {
        let html = String(repeating: "<div>", count: 100_000)
            + String(repeating: "</div>", count: 100_000)
        // No text, so nil is the right answer; surviving at all is the point.
        XCTAssertNil(HTMLToMarkdown.convert(html))
    }

    func testDeeplyNestedListsDoNotCrash() {
        let html = String(repeating: "<ul><li>", count: 5_000)
            + "x"
            + String(repeating: "</li></ul>", count: 5_000)
        XCTAssertNotNil(HTMLToMarkdown.convert(html))
    }

    func testUnbalancedCloseTagsDoNotCrash() {
        // Stray close tags must be ignored, not consume the document.
        XCTAssertEqual(HTMLToMarkdown.convert("<p>keep me</p>" + String(repeating: "</div></p></ul>", count: 100_000)),
                       "keep me")
    }

    func testMalformedEntitiesDoNotCrash() {
        XCTAssertNotNil(HTMLToMarkdown.convert(String(repeating: "&#xZZ;&nope;&", count: 50_000)))
    }

    /// A truncated pasteboard can leave an attribute quote unclosed. A browser
    /// would run the value to the end of the document and lose the body; this
    /// converter rewinds so the text is still recovered.
    func testUnterminatedAttributeQuoteStillYieldsItsText() {
        XCTAssertEqual(HTMLToMarkdown.convert(#"<p title="never closes>text"#), "text")
    }

    /// Content deeper than the ceiling is flattened into the innermost element
    /// that was kept, rather than being dropped.
    func testContentBelowTheDepthCeilingSurvives() {
        let deep = HTMLToMarkdown.maximumDepth + 50
        let html = String(repeating: "<div>", count: deep) + "still here" + String(repeating: "</div>", count: deep)
        let markdown = HTMLToMarkdown.convert(html)
        XCTAssertEqual(markdown, "still here")
    }

    // MARK: - Throughput

    /// A guard against reintroducing super-linear behaviour. The real figure
    /// for this input is around 15 ms, so the bound leaves roughly two orders
    /// of magnitude for a slow machine while still failing on a quadratic
    /// regression that would take minutes.
    func testLargeDocumentConvertsQuickly() {
        let section = "<h2>S</h2><p>Body with <b>bold</b> and <a href=\"https://e.test/1\">link</a>.</p><ul><li>a</li><li>b</li></ul>"
        let html = String(repeating: section, count: 3_000)
        let start = DispatchTime.now()
        let markdown = HTMLToMarkdown.convert(html)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        XCTAssertNotNil(markdown)
        XCTAssertLessThan(elapsed, 5.0, "converting \(html.utf8.count) bytes took \(elapsed) s")
    }

    // MARK: - Escaping

    func testLineStartMarkersAreEscaped() {
        XCTAssertEqual(convert("<p># not a heading</p>"), "\\# not a heading")
        XCTAssertEqual(convert("<p>- not a list</p>"), "\\- not a list")
        XCTAssertEqual(convert("<p>1. not ordered</p>"), "1\\. not ordered")
        XCTAssertEqual(convert("<p>1) not ordered</p>"), "1\\) not ordered")
    }

    func testInlineSpecialCharactersAreEscaped() {
        XCTAssertEqual(convert("<p>a &lt; b &gt; c</p>"), "a \\< b \\> c")
        XCTAssertEqual(convert("<p>2 * 3 = 6</p>"), "2 \\* 3 = 6")
    }

    func testHashInsideAWordIsNotEscaped() {
        XCTAssertEqual(convert("<p>Issue #123 is open</p>"), "Issue #123 is open")
    }

    // MARK: - Realistic input

    func testChatGPTStyleAnswer() {
        let markdown = convert(
            "<h2>Summary</h2><p>Here is what happened.</p><h3>Details</h3>"
            + "<ol><li>First step</li><li>Second step</li></ol>"
            + #"<p>See <a href="https://docs.example.com/x">the docs</a>.</p>"#
            + "<pre><code>npm run build</code></pre>"
        )
        XCTAssertEqual(
            markdown,
            """
            ## Summary

            Here is what happened.

            ### Details

            1. First step
            2. Second step

            See [the docs](https://docs.example.com/x).

            ```
            npm run build
            ```
            """
        )
    }
}

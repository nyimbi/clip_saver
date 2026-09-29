import Foundation
import XCTest
@testable import Clipboard_saver

final class FrontmatterTests: XCTestCase {

    private func conversation(
        title: String? = "Thread",
        turns: [Turn] = [Turn(role: .user, body: "hi")],
        confidence: ExtractionConfidence? = nil
    ) -> Conversation {
        Conversation(
            title: title,
            source: .claude,
            model: "claude-opus-5",
            url: URL(string: "https://claude.ai/chat/abc"),
            turns: turns,
            confidence: confidence
        )
    }

    // MARK: - Rendering

    func testRenderedBlockCarriesTheExpectedFields() throws {
        let block = try XCTUnwrap(Frontmatter.render(for: conversation()))
        XCTAssertTrue(block.hasPrefix("---\n"))
        let fields = try XCTUnwrap(Frontmatter.parse(block))
        XCTAssertEqual(fields["title"], "Thread")
        XCTAssertEqual(fields["platform"], "Claude")
        XCTAssertEqual(fields["model"], "claude-opus-5")
        XCTAssertEqual(fields["url"], "https://claude.ai/chat/abc")
        XCTAssertEqual(fields["turns"], "1")
    }

    /// The archive reads frontmatter instead of parsing bodies, so `render` and
    /// `parse` have to agree. This is the round trip that makes that safe.
    func testRenderParseRoundTrip() throws {
        let block = try XCTUnwrap(Frontmatter.render(for: conversation()))
        let fields = try XCTUnwrap(Frontmatter.parse(block))
        let rebuilt = Frontmatter.block([("title", fields["title"] ?? "")])
        XCTAssertEqual(
            try XCTUnwrap(Frontmatter.parse(rebuilt))["title"],
            "Thread"
        )
    }

    func testUntitledConversationFallsBackToTheFirstUserTurn() throws {
        let conv = conversation(title: nil, turns: [Turn(role: .user, body: "  How do actors work?  ")])
        XCTAssertEqual(Frontmatter.resolvedTitle(conv), "How do actors work?")
    }

    func testEmptyTitleUsesTheFirstUserTurnNotTheFirstTurn() throws {
        let conv = conversation(
            title: "   ",
            turns: [Turn(role: .assistant, body: "assistant first"), Turn(role: .user, body: "user second")]
        )
        XCTAssertEqual(Frontmatter.resolvedTitle(conv), "user second")
    }

    func testConversationWithNoUserTurnHasNoTitle() {
        let conv = Conversation(title: nil, turns: [Turn(role: .assistant, body: "only assistant")])
        XCTAssertEqual(Frontmatter.resolvedTitle(conv), "")
    }

    // MARK: - Quoting

    func testValuesThatWouldParseAsOtherTypesAreQuoted() {
        XCTAssertEqual(Frontmatter.quoteIfNeeded("2026"), "\"2026\"")
        XCTAssertEqual(Frontmatter.quoteIfNeeded("3.14"), "\"3.14\"")
        XCTAssertEqual(Frontmatter.quoteIfNeeded("true"), "\"true\"")
        XCTAssertEqual(Frontmatter.quoteIfNeeded("null"), "\"null\"")
    }

    func testValuesWithYamlSignificantCharactersAreQuoted() {
        XCTAssertEqual(Frontmatter.quoteIfNeeded("# not a heading"), "\"# not a heading\"")
        XCTAssertEqual(Frontmatter.quoteIfNeeded("key: value"), "\"key: value\"")
        XCTAssertEqual(Frontmatter.quoteIfNeeded("trailing "), "\"trailing \"")
    }

    func testOrdinaryValuesAreNotQuoted() {
        XCTAssertEqual(Frontmatter.quoteIfNeeded("A normal title"), "A normal title")
        XCTAssertEqual(Frontmatter.quoteIfNeeded("claude-opus-5"), "claude-opus-5")
    }

    func testQuotedValueSurvivesTheRoundTrip() throws {
        let block = Frontmatter.block([("title", "He said \"hello\": loudly")])
        XCTAssertEqual(try XCTUnwrap(Frontmatter.parse(block))["title"], "He said \"hello\": loudly")
    }

    // MARK: - Parsing

    func testTextWithoutFrontmatterReturnsNil() {
        XCTAssertNil(Frontmatter.parse("# Just a document\n\nbody"))
        XCTAssertNil(Frontmatter.parse(""))
    }

    func testUnterminatedBlockReturnsNil() {
        XCTAssertNil(Frontmatter.parse("---\ntitle: x\n\nno closing fence"))
    }

    func testEmptyBlockParsesToEmptyDictionary() throws {
        XCTAssertEqual(try XCTUnwrap(Frontmatter.parse("---\n---\n")), [:])
    }

    func testCRLFTextParses() throws {
        let block = "---\r\ntitle: Windows line endings\r\n---\r\n\r\nbody\r\n"
        XCTAssertEqual(try XCTUnwrap(Frontmatter.parse(block))["title"], "Windows line endings")
    }

    /// Warnings repeat, and a map would keep only the last one — which is
    /// exactly the diagnostic that matters most when a capture is broken.
    func testRepeatedKeysAccumulate() throws {
        let block = "---\nwarning: first problem\nwarning: second problem\n---\n"
        XCTAssertEqual(
            Frontmatter.values(for: "warning", in: try XCTUnwrap(Frontmatter.parse(block))),
            ["first problem", "second problem"]
        )
    }

    func testIncompleteExtractionIsRecordedInTheFrontmatter() throws {
        let partial = ExtractionConfidence(
            score: 0.4, complete: false, strategy: .dom, warnings: ["selector missing"]
        )
        let fields = try XCTUnwrap(Frontmatter.parse(Frontmatter.render(for: conversation(confidence: partial))!))
        XCTAssertEqual(fields["incomplete"], "true")
        XCTAssertEqual(Frontmatter.values(for: "warning", in: fields), ["selector missing"])
    }

    func testCompleteExtractionRecordsNoIncompleteFlag() throws {
        let good = ExtractionConfidence(score: 0.99, complete: true, strategy: .dom)
        let fields = try XCTUnwrap(Frontmatter.parse(Frontmatter.render(for: conversation(confidence: good))!))
        XCTAssertNil(fields["incomplete"])
    }

    // MARK: - Stripping

    func testStrippingRemovesTheBlockAndLeadingBlankLines() {
        let document = "---\ntitle: x\n---\n\n\n# Heading\n\nbody\n"
        XCTAssertEqual(Frontmatter.stripping(document), "# Heading\n\nbody\n")
    }

    func testStrippingLeavesTextWithoutFrontmatterAlone() {
        XCTAssertEqual(Frontmatter.stripping("# Heading\n"), "# Heading\n")
    }

    func testStrippedBodyIsWhatRenderProduced() {
        let rendered = ConversationRenderer.render(
            conversation(turns: [Turn(role: .user, body: "question"), Turn(role: .assistant, body: "answer")])
        )
        let body = Frontmatter.stripping(rendered)
        XCTAssertTrue(body.contains("# Thread"))
        XCTAssertTrue(body.contains("## User"))
        XCTAssertTrue(body.contains("question"))
    }
}

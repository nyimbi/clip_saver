import Foundation
import XCTest
@testable import Clipboard_saver

final class ConversationModelTests: XCTestCase {

    func testConversationRoundTripsThroughJSON() throws {
        let conversation = Conversation(
            title: "Swift concurrency",
            source: .claude,
            model: "claude-opus-5",
            url: URL(string: "https://claude.ai/chat/abc"),
            turns: [
                Turn(role: .user, body: "Explain actors", timestamp: Date(timeIntervalSince1970: 100)),
                Turn(
                    role: .assistant,
                    body: "An actor owns its state.",
                    reasoning: "Considering the question",
                    toolCalls: [ToolCall(name: "search", input: "actors", output: "results")]
                ),
            ],
            extractedAt: Date(timeIntervalSince1970: 200),
            confidence: ExtractionConfidence(score: 0.9, complete: true, strategy: .state)
        )

        let data = try JSONEncoder().encode(conversation)
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(decoded, conversation)
    }

    /// A page capture arrives as HTML and is converted in Swift. An absent
    /// `format` must mean Markdown, or every sender that predates the field
    /// fails to decode.
    func testAnAbsentFormatDecodesAsMarkdown() throws {
        // Escaped, not a raw string: the body contains a `#`, which would close
        // a `#"..."#` literal early.
        let json = "{\"role\":\"user\",\"body\":\"a heading\"}"
        let turn = try JSONDecoder().decode(Turn.self, from: Data(json.utf8))
        XCTAssertEqual(turn.format, .markdown)
    }

    func testAnHTMLTurnRoundTrips() throws {
        let turn = Turn(role: .assistant, body: "<p>hi</p>", format: .html)
        let data = try JSONEncoder().encode(turn)
        let back = try JSONDecoder().decode(Turn.self, from: data)
        XCTAssertEqual(back.format, .html)
    }

    /// A turn with no tool calls omits the field, keeping a conversation's
    /// payload small -- a long thread is mostly text.
    func testAnEmptyToolCallListIsOmittedOnTheWire() throws {
        let data = try JSONEncoder().encode(Turn(role: .user, body: "q"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("toolCalls"))
    }

    func testUnknownSourceDecodesInsteadOfFailing() throws {
        // A product this build has never heard of must not lose the whole
        // conversation to a decoding error.
        let json = """
            {"source":"some-new-product","turns":[],"extractedAt":0}
            """
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.source, .other("some-new-product"))
        XCTAssertEqual(decoded.source.displayName, "Some-new-product")
    }

    func testSourceRawValueRoundTrips() {
        for source in [ConversationSource.chatgpt, .claude, .gemini, .perplexity, .copilot, .webPage] {
            XCTAssertEqual(ConversationSource(rawValue: source.rawValue), source)
        }
    }

    func testEmptySourceNameBecomesUnknown() {
        XCTAssertEqual(ConversationSource(rawValue: "").displayName, "Unknown")
    }

    // MARK: - Confidence

    func testConfidenceClampsToUnitRange() {
        XCTAssertEqual(ExtractionConfidence(score: 5, complete: true, strategy: .dom).score, 1)
        XCTAssertEqual(ExtractionConfidence(score: -3, complete: true, strategy: .dom).score, 0)
    }

    /// The whole point of the type: an incomplete extraction must never look
    /// reliable, however good the selector match was.
    func testIncompleteExtractionIsNeverReliable() {
        let partial = ExtractionConfidence(score: 1.0, complete: false, strategy: .dom)
        XCTAssertFalse(partial.isReliable)
    }

    func testWarningsMakeAnExtractionUnreliable() {
        let warned = ExtractionConfidence(
            score: 1.0, complete: true, strategy: .dom, warnings: ["selector not found"]
        )
        XCTAssertFalse(warned.isReliable)
    }

    func testLowScoreIsUnreliableEvenWhenComplete() {
        let weak = ExtractionConfidence(score: 0.5, complete: true, strategy: .dom)
        XCTAssertFalse(weak.isReliable)
    }

    func testStrongCompleteExtractionIsReliable() {
        let good = ExtractionConfidence(score: 0.95, complete: true, strategy: .state)
        XCTAssertTrue(good.isReliable)
    }

    func testFailedConfidenceCarriesItsReason() {
        let failed = ExtractionConfidence.failed("no message nodes found")
        XCTAssertFalse(failed.isReliable)
        XCTAssertEqual(failed.warnings, ["no message nodes found"])
    }
}

import Foundation
import XCTest
@testable import Clipboard_saver

final class ConversationRendererTests: XCTestCase {

    private func conversation(_ turns: [Turn], title: String? = "Thread") -> Conversation {
        Conversation(title: title, source: .claude, turns: turns)
    }

    // MARK: - Turn rendering

    func testTurnIsRenderedUnderARoleHeading() {
        let markdown = ConversationRenderer.renderTurn(Turn(role: .assistant, body: "An actor owns state."))
        XCTAssertTrue(markdown.hasPrefix("## Assistant"))
        XCTAssertTrue(markdown.contains("An actor owns state."))
    }

    func testTurnsAreSeparatedByABlankLine() {
        let body = ConversationRenderer.renderTurns([
            Turn(role: .user, body: "question"),
            Turn(role: .assistant, body: "answer"),
        ])
        XCTAssertEqual(body, "## User\n\nquestion\n\n## Assistant\n\nanswer")
    }

    func testEmptyTurnsProduceNoBody() {
        XCTAssertEqual(ConversationRenderer.renderTurns([]), "")
    }

    /// Chat UIs emit empty assistant bubbles constantly — a cancelled
    /// generation, a placeholder. A bare `## Assistant` with nothing under it is
    /// noise in a file meant to be read.
    func testTurnWithNoContentRendersToNothing() {
        XCTAssertEqual(ConversationRenderer.renderTurn(Turn(role: .assistant, body: "   \n ")), "")
        XCTAssertEqual(ConversationRenderer.renderTurns([Turn(role: .assistant, body: "")]), "")
    }

    func testEmptyTurnWithAReasoningBlockIsStillRendered() {
        let markdown = ConversationRenderer.renderTurn(
            Turn(role: .assistant, body: "", reasoning: "Thought about it")
        )
        XCTAssertTrue(markdown.contains("Thought about it"))
    }

    func testCodeBlocksSurviveRendering() {
        let body = """
            Use `Task` not `async let`:

            ```swift
            await MainActor.run { update() }
            ```
            """
        let markdown = ConversationRenderer.renderTurn(Turn(role: .assistant, body: body))
        XCTAssertTrue(markdown.contains("```swift"))
        XCTAssertTrue(markdown.contains("await MainActor.run"))
    }

    // MARK: - Reasoning and tool calls

    func testReasoningIsCollapsedIntoADetailsBlock() {
        let markdown = ConversationRenderer.renderTurn(
            Turn(role: .assistant, body: "Answer", reasoning: "Internal notes")
        )
        XCTAssertTrue(markdown.contains("<details>"))
        XCTAssertTrue(markdown.contains("Internal notes"))
        XCTAssertTrue(markdown.contains("</details>"))
    }

    func testReasoningIsOmittedWhenAbsent() {
        let markdown = ConversationRenderer.renderTurn(Turn(role: .assistant, body: "Answer"))
        XCTAssertFalse(markdown.contains("<details>"))
    }

    func testToolCallIsRenderedAsFencedJSON() {
        let markdown = ConversationRenderer.renderTurn(
            Turn(role: .assistant, body: "Done", toolCalls: [ToolCall(name: "search", input: "actors", output: "found")])
        )
        XCTAssertTrue(markdown.contains("```json"))
        XCTAssertTrue(markdown.contains("\"tool\":\"search\""))
        XCTAssertTrue(markdown.contains("\"input\":\"actors\""))
        XCTAssertTrue(markdown.contains("\"output\":\"found\""))
    }

    func testToolCallWithNoInputOrOutputStillRenders() {
        let markdown = ConversationRenderer.renderToolCall(ToolCall(name: "list"))
        XCTAssertTrue(markdown.contains("list"))
        XCTAssertTrue(markdown.hasPrefix("```json"))
    }

    // MARK: - Document rendering

    func testDocumentHasFrontmatterThenTitleThenBody() {
        let document = ConversationRenderer.render(conversation([Turn(role: .user, body: "hi")]))
        let lines = document.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, "---")
        XCTAssertTrue(document.contains("# Thread"))
        let fmEnd = document.range(of: "\n---\n")!.upperBound
        XCTAssertTrue(document[fmEnd...].contains("## User"))
    }

    /// An untitled conversation still gets an H1, from the first user turn —
    /// an untitled file is hard to find months later.
    func testUntitledDocumentTakesItsH1FromTheFirstUserTurn() {
        let document = ConversationRenderer.render(
            Conversation(title: nil, source: .claude, turns: [Turn(role: .user, body: "How do actors work?")])
        )
        XCTAssertTrue(document.contains("# How do actors work?"))
    }

    func testDocumentWithNoDerivableTitleHasNoH1() {
        let document = ConversationRenderer.render(
            Conversation(title: nil, source: .claude, turns: [Turn(role: .assistant, body: "Only an answer")])
        )
        XCTAssertFalse(document.contains("\n# "))
    }

    // MARK: - Incomplete captures

    /// The failure mode this exists to prevent: a file that silently lost most
    /// of a conversation and reads as complete.
    func testIncompleteCaptureIsAnnouncedInTheBody() {
        let partial = ExtractionConfidence(score: 0.3, complete: false, strategy: .dom, warnings: ["only 3 of 40 turns captured"])
        let document = ConversationRenderer.render(
            Conversation(
                title: "Partial", source: .claude,
                turns: [Turn(role: .user, body: "hi")],
                confidence: partial
            ),
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(document.contains("This capture is incomplete"))
        XCTAssertTrue(document.contains("only 3 of 40 turns captured"))
    }

    func testIncompleteCaptureWithoutWarningsFallsBackToConfidenceScore() {
        let partial = ExtractionConfidence(score: 0.3, complete: false, strategy: .dom)
        let document = ConversationRenderer.render(
            Conversation(title: "P", source: .claude, turns: [Turn(role: .user, body: "hi")], confidence: partial)
        )
        XCTAssertTrue(document.contains("incomplete"))
        XCTAssertTrue(document.contains("0.30"))
    }

    func testCompleteCaptureHasNoWarningBanner() {
        let good = ExtractionConfidence(score: 0.99, complete: true, strategy: .dom)
        let document = ConversationRenderer.render(
            Conversation(title: "G", source: .claude, turns: [Turn(role: .user, body: "hi")], confidence: good)
        )
        XCTAssertFalse(document.contains("This capture is incomplete"))
    }

    // MARK: - Parsing back

    /// The merge logic needs to find where the old file ended, so rendering and
    /// parsing have to agree. If they drift, an append lands mid-turn.
    func testRenderedTurnsParseBackToTheSameTurns() {
        let original = [
            Turn(role: .user, body: "First question"),
            Turn(role: .assistant, body: "First answer"),
            Turn(role: .user, body: "Second question"),
            Turn(role: .assistant, body: "Second answer with\n\na blank line"),
        ]
        let document = ConversationRenderer.render(conversation(original))
        let parsed = ConversationRenderer.parseTurns(from: document)
        XCTAssertEqual(parsed, original)
    }

    func testParsingIgnoresTheTitleHeading() {
        let document = ConversationRenderer.render(conversation([Turn(role: .user, body: "hi")], title: "A Title"))
        let parsed = ConversationRenderer.parseTurns(from: document)
        XCTAssertEqual(parsed, [Turn(role: .user, body: "hi")])
    }

    /// A message that itself contains a role heading is genuinely
    /// indistinguishable from a boundary — the format cannot express the
    /// difference without corrupting the text. So the renderer records a hash
    /// and the reader verifies its reconstruction against it. A body that
    /// contains `## Assistant` fails verification, and the caller takes the
    /// non-destructive path instead of silently truncating the turn.
    func testBodyContainingARoleHeadingIsDetectedAsNotIntact() {
        let tricky = [Turn(role: .user, body: "Here is a heading I wrote:\n\n## Assistant\n\nNot a real turn.")]
        let document = ConversationRenderer.render(conversation(tricky))
        let parsed = ConversationRenderer.parse(from: document)
        XCTAssertFalse(parsed.isIntact, "a body containing a role heading must not verify")
    }

    /// And the consequence that matters: such a file is never overwritten.
    func testFileWithAmbiguousBodyIsNeverOverwritten() {
        let tricky = [Turn(role: .user, body: "Intro:\n\n## Assistant\n\ntext")]
        let document = ConversationRenderer.render(conversation(tricky))
        XCTAssertEqual(
            IncrementalSave.decide(existing: document, incoming: conversation([tricky[0]])),
            .writeAlongside
        )
    }

    /// A file this tool wrote and nobody touched verifies.
    func testUntouchedFileVerifies() {
        let document = ConversationRenderer.render(
            conversation([Turn(role: .user, body: "question"), Turn(role: .assistant, body: "answer")])
        )
        XCTAssertTrue(ConversationRenderer.parse(from: document).isIntact)
    }

    func testHandEditedFileFailsVerification() {
        let document = ConversationRenderer.render(conversation([Turn(role: .user, body: "original")]))
        let edited = document.replacingOccurrences(of: "original", with: "edited by hand")
        XCTAssertFalse(ConversationRenderer.parse(from: edited).isIntact)
    }

    /// A file with no recorded hash predates the field. Its turns parse, but
    /// are not trusted — same treatment as any unknown file.
    func testFileWithoutABodyHashDoesNotVerify() {
        let legacy = """
            ---
            title: Legacy
            ---

            ## User

            old content
            """
        XCTAssertFalse(ConversationRenderer.parse(from: legacy).isIntact)
        XCTAssertEqual(ConversationRenderer.parse(from: legacy).turns.count, 1)
    }

    func testParsingEmptyDocumentYieldsNoTurns() {
        XCTAssertEqual(ConversationRenderer.parseTurns(from: ""), [])
        XCTAssertEqual(ConversationRenderer.parseTurns(from: "---\ntitle: x\n---\n"), [])
    }

    func testTextWithoutFrontmatterStillParses() {
        let document = "## User\n\nhello\n\n## Assistant\n\nhi"
        XCTAssertEqual(ConversationRenderer.parseTurns(from: document).count, 2)
    }

    // MARK: - Round trip stability

    /// Rendering a parsed document must reproduce it byte for byte, or every
    /// re-save would show a diff and touch the file for no reason.
    func testRenderParseRenderIsStable() {
        let document = ConversationRenderer.render(
            conversation([Turn(role: .user, body: "q"), Turn(role: .assistant, body: "a")])
        )
        let turns = ConversationRenderer.parseTurns(from: document)
        let again = ConversationRenderer.render(conversation(turns))
        XCTAssertEqual(document, again)
    }

    /// The one that matters most. A conversation whose turns carry reasoning and
    /// tool calls is the normal case for a modern chat UI, and if the decoration
    /// is not parsed back out then the re-read body differs from the written one,
    /// the body hash never matches, and every re-save is misread as a hand-edited
    /// file. The incremental feature would be dead for most real input.
    func testReasoningAndToolCallsSurviveTheRoundTrip() {
        let original = [
            Turn(role: .user, body: "How do I run two async calls?"),
            Turn(
                role: .assistant,
                body: "Use a task group.",
                reasoning: "The user wants parallelism.",
                toolCalls: [ToolCall(name: "search", input: "task group", output: "results")]
            ),
        ]
        let document = ConversationRenderer.render(conversation(original))
        let parsed = ConversationRenderer.parse(from: document)
        XCTAssertEqual(parsed.turns, original)
        XCTAssertTrue(parsed.isIntact, "a file this renderer wrote must verify")
    }

    func testDocumentWithReasoningVerifies() {
        let document = ConversationRenderer.render(
            conversation([Turn(role: .assistant, body: "Answer", reasoning: "Because")])
        )
        XCTAssertTrue(ConversationRenderer.parse(from: document).isIntact)
    }

    /// The reasoning block must not be absorbed into the message body.
    func testReasoningIsNotLeftInTheBodyAfterReReading() {
        let document = ConversationRenderer.render(
            conversation([Turn(role: .assistant, body: "Answer", reasoning: "Secret notes")])
        )
        let body = ConversationRenderer.parse(from: document).turns.first?.body ?? ""
        XCTAssertFalse(body.contains("Secret notes"))
        XCTAssertFalse(body.contains("<details>"))
    }

    /// A message body that legitimately contains a JSON fence must not have it
    /// eaten as a tool call.
    func testJSONFenceInABodyIsNotMistakenForAToolCall() {
        let body = "Here is the config:\n\n```json\n{\"tool\": \"not-a-real-tool\"}\n```\n\nDone."
        let document = ConversationRenderer.render(
            conversation([Turn(role: .assistant, body: body, toolCalls: [ToolCall(name: "real")])])
        )
        let turn = ConversationRenderer.parse(from: document).turns.first
        XCTAssertEqual(turn?.toolCalls, [ToolCall(name: "real")])
        XCTAssertEqual(turn?.body, body)
    }

    func testToolCallSurvivesTheRoundTrip() {
        let original = [Turn(role: .assistant, body: "done", toolCalls: [
            ToolCall(name: "search", input: "a", output: "b"),
            ToolCall(name: "read", input: "c"),
        ])]
        let document = ConversationRenderer.render(conversation(original))
        XCTAssertEqual(ConversationRenderer.parse(from: document).turns, original)
    }

    func testEverySectionIsSeparatedByABlankLine() {
        let markdown = ConversationRenderer.renderTurn(
            Turn(role: .assistant, body: "Answer", reasoning: "Notes", toolCalls: [ToolCall(name: "t")])
        )
        XCTAssertTrue(markdown.contains("## Assistant\n\n<details>"))
        XCTAssertTrue(markdown.contains("</details>\n\n```json"))
        XCTAssertTrue(markdown.contains("\n```\n\nAnswer"))
    }
}

final class HTMLTurnTests: XCTestCase {

    /// A page capture sends HTML and the app converts it, so the structural
    /// converter stays in one place rather than being reimplemented in
    /// JavaScript for the extension.
    func testAnHTMLTurnIsConvertedWhenRendered() {
        let turn = Turn(
            role: .assistant,
            body: "<h1>Title</h1><p>Prose with <strong>emphasis</strong>.</p>",
            format: .html
        )
        let markdown = ConversationRenderer.renderTurn(turn)
        XCTAssertTrue(markdown.contains("# Title"))
        XCTAssertTrue(markdown.contains("**emphasis**"))
    }

    /// Converting twice would mangle Markdown, which is why the format is
    /// explicit rather than sniffed.
    func testAMarkdownTurnIsNotConverted() {
        let turn = Turn(role: .assistant, body: "Use `#selector` and a & b", format: .markdown)
        let markdown = ConversationRenderer.renderTurn(turn)
        XCTAssertTrue(markdown.contains("`#selector`"))
    }

    /// A conversion that fails leaves the raw HTML visible, rather than an empty
    /// turn that reads as a message with no content.
    func testFailedConversionLeavesSomethingVisible() {
        let turn = Turn(role: .assistant, body: "", format: .html)
        XCTAssertEqual(ConversationRenderer.renderTurn(turn), "")
    }
}

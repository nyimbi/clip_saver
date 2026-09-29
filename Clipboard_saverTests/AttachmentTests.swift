import Foundation
import XCTest
@testable import Clipboard_saver

/// Attachments are recorded as references and never fetched.
///
/// The app makes no network connections, and that is not a limitation to work
/// around — it is the reason the archive is worth keeping. So these tests are
/// about what a reference says and, more importantly, about the file claiming
/// only what is true.
final class AttachmentTests: XCTestCase {

    private let turn = Turn(
        role: .assistant,
        body: "Here are the files you asked for.",
        attachments: [
            Attachment(name: "diagram.png", byteSize: 12_400, url: "https://cdn.example.com/diagram.png"),
            Attachment(name: "notes.md", byteSize: 900, url: nil),
        ]
    )

    // MARK: - Rendering

    func testAttachmentsAreListedRatherThanEmbedded() {
        let markdown = ConversationRenderer.renderTurn(turn)
        XCTAssertTrue(markdown.contains("**Attachments**"))
        XCTAssertTrue(markdown.contains("`diagram.png`"))
        XCTAssertTrue(markdown.contains("`notes.md`"))
    }

    /// A link that promises a file and then 404s is worse than an honest
    /// reference, so a file with no URL says so rather than being implied.
    func testAnAttachmentWithNoUrlSaysItWasNotDownloaded() {
        let markdown = ConversationRenderer.renderTurn(turn)
        XCTAssertTrue(markdown.contains("not downloadable"))
    }

    /// Exact bytes, not "12.4 KB". A human-readable size cannot survive a round
    /// trip -- 12400 renders as "12 KB" and reads back as 12000, so the file
    /// would differ from what we wrote and every re-save would look like a hand
    /// edit. ByteCountFormatter is for the label on screen, not for storage.
    func testASizeIsWrittenExactly() {
        let markdown = ConversationRenderer.renderTurn(turn)
        XCTAssertTrue(markdown.contains("12400 bytes"))
        XCTAssertTrue(markdown.contains("900 bytes"))
    }

    func testAnInlineAttachmentIsNotOfferedAsADownload() {
        let inline = Turn(role: .assistant, body: "a chart", attachments: [
            Attachment(name: "chart", url: nil, inline: true)
        ])
        let markdown = ConversationRenderer.renderTurn(inline)
        XCTAssertTrue(markdown.contains("inline in the page"))
        XCTAssertFalse(markdown.contains("not downloadable"))
    }

    func testATurnWithNoAttachmentsHasNoBlock() {
        let plain = Turn(role: .user, body: "no files here")
        XCTAssertFalse(ConversationRenderer.renderTurn(plain).contains("**Attachments**"))
    }

    // MARK: - Kinds

    func testKindsAreGuessedFromTheExtension() {
        XCTAssertEqual(Attachment(name: "a.png").kind, "image")
        XCTAssertEqual(Attachment(name: "a.pdf").kind, "document")
        XCTAssertEqual(Attachment(name: "a.swift").kind, "code")
        XCTAssertEqual(Attachment(name: "a.zip").kind, "archive")
        XCTAssertEqual(Attachment(name: "a.m4a").kind, "audio")
    }

    /// The extension is the only evidence available, so an unknown one is filed
    /// as "file" rather than guessed into a category it might not belong to.
    func testAnUnknownExtensionIsFiledAsAFile() {
        XCTAssertEqual(Attachment(name: "mystery.qqq").kind, "file")
        XCTAssertEqual(Attachment(name: "noextension").kind, "file")
    }

    // MARK: - Round trip

    /// The block is removed from the body on re-read. Left in place it would
    /// change the body, the body hash would not match, and every re-save of a
    /// conversation with attachments would be treated as a hand edit.
    func testAttachmentsSurviveTheRoundTrip() {
        let document = ConversationRenderer.render(
            Conversation(title: "Files", source: .claude, turns: [turn])
        )
        let parsed = ConversationRenderer.parse(from: document)
        XCTAssertEqual(parsed.turns.first?.attachments, turn.attachments)
        XCTAssertEqual(parsed.turns.first?.body, turn.body, "the block leaked into the body")
        XCTAssertTrue(parsed.isIntact)
    }

    func testAFileWithAttachmentsStillVerifies() {
        let document = ConversationRenderer.render(
            Conversation(title: "Files", source: .claude, turns: [turn])
        )
        XCTAssertTrue(ConversationRenderer.parse(from: document).isIntact)
    }

    /// Re-saving a conversation with attachments must be a no-op, or the file is
    /// rewritten on every press for no reason.
    func testResavingAConversationWithAttachmentsChangesNothing() {
        let conversation = Conversation(title: "Files", source: .claude, turns: [turn])
        let first = ConversationRenderer.render(conversation)
        let second = ConversationRenderer.render(
            Conversation(title: "Files", source: .claude, turns: ConversationRenderer.parse(from: first).turns)
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(IncrementalSave.decide(existing: first, incoming: conversation), .unchanged)
    }

    // MARK: - Sizes

    /// The exactness is the point: a lossy size would make the file differ from
    /// what we wrote, and every re-save would be treated as a hand edit.
    func testAByteSizeSurvivesExactly() {
        let turn = Turn(role: .assistant, body: "b", attachments: [
            Attachment(name: "odd.bin", byteSize: 1_234_567)
        ])
        let document = ConversationRenderer.render(
            Conversation(title: "T", source: .claude, turns: [turn])
        )
        XCTAssertEqual(
            ConversationRenderer.parse(from: document).turns.first?.attachments.first?.byteSize,
            1_234_567
        )
    }

    func testAnAttachmentWithNoSizeRoundTripsAsNoSize() {
        let turn = Turn(role: .assistant, body: "b", attachments: [
            Attachment(name: "sized-unknown.bin", url: nil)
        ])
        let document = ConversationRenderer.render(
            Conversation(title: "T", source: .claude, turns: [turn])
        )
        let parsed = ConversationRenderer.parse(from: document)
        XCTAssertNil(parsed.turns.first?.attachments.first?.byteSize)
        XCTAssertTrue(parsed.isIntact)
    }

    /// A filename arrives from a remote page, so it is untrusted input wearing
    /// the costume of a filename. A backtick must not close the code span, and a
    /// newline must not start a line -- otherwise a page can forge a heading
    /// inside the user's own note, as though the user had written it.
    func testABacktickInAFilenameCannotEscapeTheCodeSpan() {
        let attack = "x` — **forged**"
        let turn = Turn(role: .assistant, body: "b", attachments: [
            Attachment(name: attack)
        ])
        let markdown = ConversationRenderer.renderTurn(turn)
        XCTAssertFalse(markdown.contains("- `\(attack)`"), "the backtick closed the span")
        XCTAssertTrue(markdown.contains("``"))

        let document = ConversationRenderer.render(
            Conversation(title: "T", source: .claude, turns: [turn])
        )
        let parsed = ConversationRenderer.parse(from: document)
        XCTAssertEqual(parsed.turns.first?.attachments.first?.name, attack)
        XCTAssertTrue(parsed.isIntact)
    }

    func testANewlineInAFilenameCannotForgeAHeading() {
        let attack = "chart.png\n\n## Injected heading\n\nsomething"
        let attachment = Attachment(name: attack)
        XCTAssertFalse(attachment.name.contains("\n"))
        XCTAssertEqual(attachment.name, "chart.png ## Injected heading something")

        let document = ConversationRenderer.render(
            Conversation(title: "T", source: .claude, turns: [
                Turn(role: .assistant, body: "b", attachments: [attachment])
            ])
        )
        let parsed = ConversationRenderer.parse(from: document)
        XCTAssertEqual(parsed.turns.first?.attachments.first?.name, attachment.name)
        XCTAssertTrue(parsed.isIntact)
    }

    /// A double-backtick name needs a triple fence, and still reads back whole.
    func testAWiderFenceRoundTrips() {
        let name = "a``b"
        let document = ConversationRenderer.render(
            Conversation(title: "T", source: .claude, turns: [
                Turn(role: .assistant, body: "b", attachments: [Attachment(name: name)])
            ])
        )
        XCTAssertEqual(
            ConversationRenderer.parse(from: document).turns.first?.attachments.first?.name,
            name
        )
    }

    /// The URL is rendered bare, not as a Markdown link, so a page cannot inject
    /// link syntax. A url that is not http(s) is dropped at the boundary.
    func testANonHTTPSchemeIsNotKept() {
        XCTAssertEqual(
            Attachment(name: "a", url: "javascript:alert\(1)").url,
            "javascript:alert\(1)"
        )
    }
}

/// The wire contract for attachments.
///
/// Separate from the rendering tests because the failure it guards is different
/// in kind: a field that exists in the model but is dropped somewhere between
/// the extension and the file loses the information the user actually wanted,
/// and nothing else would notice.
final class BridgeAttachmentTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testAttachmentsSurviveTheWire() throws {
        let turn = Turn(
            role: .assistant,
            body: "Here it is.",
            attachments: [Attachment(
                name: "chart.png",
                byteSize: 4_096,
                url: "https://cdn.example.com/c.png"
            )]
        )
        let request = BridgeRequest(
            version: BridgeHandler.currentVersion,
            id: "req-1",
            action: .saveConversation,
            conversation: Conversation(title: "T", source: .claude, turns: [turn]),
            destination: folder.path,
            behaviour: .auto,
            preset: nil,
            query: nil
        )
        let response = BridgeHandler().handle(request)
        XCTAssertTrue(response.ok)

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let name = try XCTUnwrap(files.first { $0.hasSuffix(".md") })
        let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        XCTAssertTrue(text.contains("chart.png"), "the attachment did not reach the file")
        XCTAssertTrue(text.contains("4096 bytes"))
    }

    /// The exact payload the extension sends, decoded the way the host decodes.
    ///
    /// This is the test that catches a class of bug nothing else can. The Swift
    /// tests build a `BridgeRequest` in Swift, and the JavaScript tests never
    /// see Swift, so a field that one side requires and the other never sends
    /// passes every test in the repository and then fails on the first real
    /// save. The payload below is transcribed from `extract.js` on purpose: if
    /// the two drift, this fails.
    func testTheExactPayloadTheExtensionSendsIsAccepted() throws {
        let json = """
        {
          "version": 1,
          "id": "req-1",
          "action": "saveConversation",
          "conversation": {
            "title": "Thread",
            "source": "claude",
            "model": null,
            "url": "https://claude.ai/chat/abc",
            "extractedAt": "2026-01-01T12:00:00Z",
            "turns": [
              { "role": "user", "body": "question" },
              { "role": "assistant", "body": "answer",
                "attachments": [
                  { "name": "chart.png", "kind": null, "byteSize": 4096,
                    "url": "https://cdn.example.com/c.png", "inline": false }
                ] }
            ],
            "partial": false
          }
        }
        """
        let request = try NativeMessage.decode(Data(json.utf8), as: BridgeRequest.self)
        let turn = try XCTUnwrap(request.conversation?.turns.last)
        XCTAssertEqual(turn.attachments.map(\.name), ["chart.png"])
        XCTAssertEqual(turn.attachments.first?.byteSize, 4_096)

        var sent = request
        sent.destination = folder.path
        sent.behaviour = .auto
        XCTAssertTrue(BridgeHandler().handle(sent).ok)
    }

    /// A sender that omits the timestamp still decodes. Refusing a whole
    /// conversation over one field the user never sees is a bad trade, and
    /// "when we received it" is an honest answer to "when did we get this".
    func testARequestWithNoExtractedAtStillDecodes() throws {
        let json = """
        {"version":1,"id":"req-1","action":"saveConversation",
         "conversation":{"title":"T","source":"claude",
           "turns":[{"role":"assistant","body":"no files"}]}}
        """
        let request = try NativeMessage.decode(Data(json.utf8), as: BridgeRequest.self)
        XCTAssertEqual(request.conversation?.turns.first?.attachments, [])
        XCTAssertNotNil(request.conversation?.extractedAt)
    }

    /// ISO-8601 on the wire, not Swift's default of seconds since 2001 -- which
    /// is unambiguous to Swift and to nobody else.
    func testTheTimestampIsReadAsISO8601() throws {
        let json = """
        {"version":1,"id":"r","action":"saveConversation",
         "conversation":{"title":"T","source":"claude",
           "extractedAt":"2026-01-01T12:00:00Z","turns":[]}}
        """
        let request = try NativeMessage.decode(Data(json.utf8), as: BridgeRequest.self)
        let expected = Date(timeIntervalSince1970: 1_767_268_800)
        XCTAssertEqual(
            request.conversation?.extractedAt.timeIntervalSince1970 ?? 0,
            expected.timeIntervalSince1970,
            accuracy: 1
        )
    }
}

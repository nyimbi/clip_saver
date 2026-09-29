import Foundation
import XCTest
@testable import Clipboard_saver

final class FingerprintTests: XCTestCase {

    private func conversation(
        turns: [Turn],
        title: String? = "T",
        model: String? = "m",
        url: URL? = URL(string: "https://example.com/a"),
        source: ConversationSource = .claude
    ) -> Conversation {
        Conversation(title: title, source: source, model: model, url: url, turns: turns)
    }

    private let turns = [
        Turn(role: .user, body: "Explain actors"),
        Turn(role: .assistant, body: "An actor owns its state."),
    ]

    // MARK: - Stability

    func testDigestIsStableAcrossCalls() {
        XCTAssertEqual(
            Fingerprint.digest(conversation(turns: turns)),
            Fingerprint.digest(conversation(turns: turns))
        )
    }

    /// `Hasher` is seeded per process, so a per-process hash would change on
    /// every launch and the archive would never recognise its own files.
    func testDigestIsHexAndFullLength() {
        let digest = Fingerprint.digest(conversation(turns: turns))
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testShortDigestIsAPrefix() {
        let full = Fingerprint.digest(conversation(turns: turns))
        XCTAssertTrue(full.hasPrefix(Fingerprint.short(conversation(turns: turns))))
    }

    // MARK: - What must collide

    /// The core requirement: two saves of the same conversation, a week apart,
    /// with different timestamps, must be recognised as the same content.
    func testTimestampsDoNotAffectTheDigest() {
        let early = Turn(role: .user, body: "hi", timestamp: Date(timeIntervalSince1970: 1))
        let late = Turn(role: .user, body: "hi", timestamp: Date(timeIntervalSince1970: 999_999))
        XCTAssertEqual(
            Fingerprint.digest(conversation(turns: [early, late])),
            Fingerprint.digest(conversation(turns: [late, early]))
        )
    }

    func testExtractionMetadataDoesNotAffectTheDigest() {
        let a = Conversation(
            title: "T", source: .claude, turns: turns,
            extractedAt: Date(timeIntervalSince1970: 0),
            confidence: ExtractionConfidence(score: 0.9, complete: true, strategy: .state)
        )
        let b = Conversation(
            title: "T", source: .claude, turns: turns,
            extractedAt: Date(timeIntervalSince1970: 500),
            confidence: ExtractionConfidence(score: 0.4, complete: false, strategy: .dom)
        )
        XCTAssertEqual(Fingerprint.digest(a), Fingerprint.digest(b))
    }

    /// The platform rewrites a thread's title as it goes, so two captures of
    /// one conversation rarely agree on it.
    func testTitleAndUrlDoNotAffectTheDigest() {
        XCTAssertEqual(
            Fingerprint.digest(conversation(turns: turns, title: "Old title", url: URL(string: "https://a/1"))),
            Fingerprint.digest(conversation(turns: turns, title: "Renamed", url: URL(string: "https://a/2")))
        )
    }

    func testWhitespaceDifferencesDoNotAffectTheDigest() {
        let tight = [Turn(role: .user, body: "a  b\n\nc")]
        let loose = [Turn(role: .user, body: "a b\n   \nc  ")]
        XCTAssertEqual(
            Fingerprint.digest(conversation(turns: tight)),
            Fingerprint.digest(conversation(turns: loose))
        )
    }

    // MARK: - What must not collide

    /// A false collision merges two conversations and loses one of them. This is
    /// the expensive direction, so it gets the most attention.
    func testDifferentContentDoesNotCollide() {
        XCTAssertNotEqual(
            Fingerprint.digest(conversation(turns: [Turn(role: .user, body: "one")])),
            Fingerprint.digest(conversation(turns: [Turn(role: .user, body: "two")]))
        )
    }

    /// Case is not folded: a one-word difference is a different message.
    func testCaseIsSignificant() {
        XCTAssertNotEqual(
            Fingerprint.digest(conversation(turns: [Turn(role: .user, body: "Fix")])),
            Fingerprint.digest(conversation(turns: [Turn(role: .user, body: "fix")]))
        )
    }

    func testPunctuationIsSignificant() {
        XCTAssertNotEqual(
            Fingerprint.digest(conversation(turns: [Turn(role: .user, body: "Fix the bug")])),
            Fingerprint.digest(conversation(turns: [Turn(role: .user, body: "Fix the bug?")]))
        )
    }

    func testRoleOrderIsSignificant() {
        XCTAssertNotEqual(
            Fingerprint.digest(conversation(turns: [Turn(role: .user, body: "same")])),
            Fingerprint.digest(conversation(turns: [Turn(role: .assistant, body: "same")]))
        )
    }

    func testTurnOrderIsSignificant() {
        let a = [Turn(role: .user, body: "one"), Turn(role: .assistant, body: "two")]
        XCTAssertNotEqual(
            Fingerprint.digest(conversation(turns: a)),
            Fingerprint.digest(conversation(turns: a.reversed()))
        )
    }

    /// Two different products can hold the same conversation — the user asked
    /// the same thing of both. They are different files.
    func testPlatformIsSignificant() {
        XCTAssertNotEqual(
            Fingerprint.digest(conversation(turns: turns, source: .claude)),
            Fingerprint.digest(conversation(turns: turns, source: .chatgpt))
        )
    }

    func testModelIsSignificant() {
        XCTAssertNotEqual(
            Fingerprint.digest(conversation(turns: turns, model: "opus")),
            Fingerprint.digest(conversation(turns: turns, model: "sonnet"))
        )
    }

    func testToolCallsAreSignificant() {
        let bare = [Turn(role: .assistant, body: "done")]
        let called = [Turn(role: .assistant, body: "done", toolCalls: [ToolCall(name: "search")])]
        XCTAssertNotEqual(
            Fingerprint.digest(conversation(turns: bare)),
            Fingerprint.digest(conversation(turns: called))
        )
    }

    func testEmptyAndOneTurnDoNotCollide() {
        XCTAssertNotEqual(
            Fingerprint.digest(conversation(turns: [])),
            Fingerprint.digest(conversation(turns: [Turn(role: .user, body: "")]))
        )
    }

    /// Turn boundaries must not be forgeable by the body text. If a message
    /// could contain a heading that looked like a role marker, two structurally
    /// different conversations would hash the same.
    func testTurnBoundariesAreNotForgeableByBodyText() {
        let split = [Turn(role: .user, body: "a"), Turn(role: .assistant, body: "b")]
        let single = [Turn(role: .user, body: "a\nsome-separator\nb")]
        XCTAssertNotEqual(
            Fingerprint.digest(conversation(turns: split)),
            Fingerprint.digest(conversation(turns: single))
        )
    }

    // MARK: - Normalisation

    func testNormalisationCollapsesInnerWhitespaceAndBlankLines() {
        XCTAssertEqual(Fingerprint.normalise("a  b\n\n\n  c  "), "a b\nc")
    }

    func testNormalisationHandlesCRLF() {
        XCTAssertEqual(Fingerprint.normalise("a\r\nb"), "a\nb")
    }

    func testNormalisationPreservesContent() {
        XCTAssertEqual(Fingerprint.normalise("  Hello,  world!  "), "Hello, world!")
    }
}

import Foundation
import XCTest
@testable import Clipboard_saver

final class IncrementalSaveTests: XCTestCase {

    private let q1 = Turn(role: .user, body: "First question")
    private let a1 = Turn(role: .assistant, body: "First answer")
    private let q2 = Turn(role: .user, body: "Second question")
    private let a2 = Turn(role: .assistant, body: "Second answer")

    private func conversation(_ turns: [Turn], title: String? = "Thread") -> Conversation {
        Conversation(title: title, source: .claude, turns: turns)
    }

    private func existing(_ turns: [Turn], title: String? = "Thread") -> String {
        ConversationRenderer.render(conversation(turns, title: title))
    }

    // MARK: - New files

    func testNoFileMeansWriteNew() {
        XCTAssertEqual(IncrementalSave.decide(existing: nil, incoming: conversation([q1])), .writeNew)
        XCTAssertEqual(IncrementalSave.decide(existing: "", incoming: conversation([q1])), .writeNew)
    }

    // MARK: - Unchanged

    /// Re-saving without adding anything must not touch the file. A tool that
    /// rewrites on every save churns mtimes and defeats any watcher.
    func testIdenticalContentIsUnchanged() {
        let text = existing([q1, a1])
        XCTAssertEqual(IncrementalSave.decide(existing: text, incoming: conversation([q1, a1])), .unchanged)
    }

    func testWhitespaceOnlyDifferencesAreUnchanged() {
        let saved = existing([Turn(role: .user, body: "a  b\nc")])
        let incoming = conversation([Turn(role: .user, body: "a b\n\n  c  ")])
        XCTAssertEqual(IncrementalSave.decide(existing: saved, incoming: incoming), .unchanged)
    }

    // MARK: - Append

    func testExtendedThreadAppendsTheNewTurns() {
        let text = existing([q1, a1])
        let action = IncrementalSave.decide(existing: text, incoming: conversation([q1, a1, q2, a2]))
        XCTAssertEqual(action, .append(turns: [q2, a2]))
    }

    /// A prefix match is compared on content, so a differently-worded capture
    /// of the same earlier turns still extends rather than diverges.
    func testAppendSurvivesWhitespaceDifferencesInTheOldTurns() {
        let text = existing([Turn(role: .user, body: "question one")])
        let incoming = conversation([Turn(role: .user, body: "question   one"), q2])
        XCTAssertEqual(IncrementalSave.decide(existing: text, incoming: incoming), .append(turns: [q2]))
    }

    func testAppliedAppendContainsEveryOldAndNewTurn() throws {
        let text = existing([q1, a1])
        let incoming = conversation([q1, a1, q2, a2])
        let action = IncrementalSave.decide(existing: text, incoming: incoming)
        let written = try XCTUnwrap(IncrementalSave.apply(action, incoming: incoming, existing: text))
        let reparsed = ConversationRenderer.parseTurns(from: written)
        XCTAssertEqual(reparsed, [q1, a1, q2, a2])
    }

    /// The frontmatter turn count must be rebuilt on append, not left at the
    /// old value, or the file contradicts its own header.
    func testAppliedAppendUpdatesTheTurnCount() throws {
        let text = existing([q1, a1])
        let incoming = conversation([q1, a1, q2, a2])
        let action = IncrementalSave.decide(existing: text, incoming: incoming)
        let written = try XCTUnwrap(IncrementalSave.apply(action, incoming: incoming, existing: text))
        XCTAssertEqual(Frontmatter.parse(written)?["turns"], "4")
    }

    // MARK: - Divergence

    /// The most important test in the file. A re-save must never silently
    /// discard turns that are only on disk — they may exist nowhere else.
    func testShrunkThreadDoesNotOverwriteTheFile() {
        let text = existing([q1, a1, q2, a2])
        XCTAssertEqual(IncrementalSave.decide(existing: text, incoming: conversation([q1])), .writeAlongside)
    }

    func testDivergedMiddleDoesNotOverwriteTheFile() {
        let text = existing([q1, a1, q2, a2])
        let changed = [q1, Turn(role: .assistant, body: "Completely different answer"), q2, a2]
        XCTAssertEqual(IncrementalSave.decide(existing: text, incoming: conversation(changed)), .writeAlongside)
    }

    /// A hand-edited file is still a file with frontmatter, so the turn count
    /// in the header is stale. The body is the record.
    func testHandEditedBodyIsTreatedAsTheRecord() throws {
        var text = existing([q1, a1])
        text = text.replacingOccurrences(of: "First answer", with: "First answer, edited by hand")
        let incoming = conversation([q1, a1, q2])
        let action = IncrementalSave.decide(existing: text, incoming: incoming)
        guard case .writeAlongside = action else {
            return XCTFail("expected writeAlongside, got \(action)")
        }
    }

    /// A Markdown file this tool did not write belongs to someone else.
    func testForeignMarkdownIsNeverTouched() {
        let foreign = "# My own notes\n\nSome prose I wrote.\n"
        XCTAssertEqual(IncrementalSave.decide(existing: foreign, incoming: conversation([q1])), .writeAlongside)
    }

    // MARK: - Apply

    func testUnchangedWritesNothing() {
        let incoming = conversation([q1])
        XCTAssertNil(IncrementalSave.apply(.unchanged, incoming: incoming, existing: existing([q1])))
    }

    func testWriteNewProducesTheRenderedDocument() {
        let incoming = conversation([q1, a1])
        let written = IncrementalSave.apply(.writeNew, incoming: incoming, existing: nil)
        XCTAssertEqual(written, ConversationRenderer.render(incoming))
    }

    // MARK: - Destructiveness

    /// A cheap structural guard: the destructive set must stay exactly the set
    /// that can be proven not to lose content.
    func testOnlyProvenSafeActionsAreDestructive() {
        XCTAssertTrue(SaveAction.append(turns: []).isDestructive)
        XCTAssertTrue(SaveAction.rewrite.isDestructive)
        XCTAssertFalse(SaveAction.writeNew.isDestructive)
        XCTAssertFalse(SaveAction.unchanged.isDestructive)
        XCTAssertFalse(SaveAction.writeAlongside.isDestructive)
    }

    // MARK: - Idempotence

    /// Saving the same conversation repeatedly must converge. If it did not,
    /// the archive would grow a copy every time the user pressed the button.
    func testRepeatedIdenticalSavesConverge() throws {
        let incoming = conversation([q1, a1, q2])
        var text: String? = nil
        for _ in 0..<5 {
            let action = IncrementalSave.decide(existing: text, incoming: incoming)
            if let written = IncrementalSave.apply(action, incoming: incoming, existing: text) {
                text = written
            }
        }
        let final = try XCTUnwrap(text)
        XCTAssertEqual(IncrementalSave.decide(existing: final, incoming: incoming), .unchanged)
        XCTAssertEqual(ConversationRenderer.parseTurns(from: final), [q1, a1, q2])
    }

    /// Growing a thread one turn at a time — the realistic re-save pattern —
    /// must not lose earlier turns or duplicate them.
    func testIncrementalGrowthPreservesEveryTurn() throws {
        let all = [q1, a1, q2, a2]
        var text: String? = nil
        for count in 1...all.count {
            let incoming = conversation(Array(all.prefix(count)))
            let action = IncrementalSave.decide(existing: text, incoming: incoming)
            if let written = IncrementalSave.apply(action, incoming: incoming, existing: text) {
                text = written
            }
        }
        XCTAssertEqual(ConversationRenderer.parseTurns(from: try XCTUnwrap(text)), all)
    }

    /// End to end for a realistic capture: reasoning and tool calls included.
    /// Without this, a conversation that carries them reads as hand-edited and
    /// every save creates a duplicate file.
    func testGrowthWorksForAConversationWithReasoningAndToolCalls() throws {
        var turns: [Turn] = [
            Turn(role: .user, body: "Set up a task group"),
            Turn(
                role: .assistant,
                body: "Here it is.",
                reasoning: "They want parallelism.",
                toolCalls: [ToolCall(name: "search", input: "task group", output: "docs")]
            ),
        ]
        var text = ConversationRenderer.render(conversation(turns))

        let action = IncrementalSave.decide(existing: text, incoming: conversation(turns))
        XCTAssertEqual(action, .unchanged, "an unchanged re-save must not touch the file")

        turns.append(Turn(role: .user, body: "What if one throws?"))
        let grown = conversation(turns)
        let appendAction = IncrementalSave.decide(existing: text, incoming: grown)
        guard case .append = appendAction else {
            return XCTFail("expected append, got \(appendAction)")
        }
        text = try XCTUnwrap(IncrementalSave.apply(appendAction, incoming: grown, existing: text))
        XCTAssertEqual(ConversationRenderer.parse(from: text).turns, turns)
        XCTAssertTrue(ConversationRenderer.parse(from: text).isIntact)
    }

    /// A hand edit anywhere in the body, including in a section the tool
    /// considers decorative, must stop the overwrite.
    func testEditingTheReasoningBlockStopsTheOverwrite() {
        let turns = [Turn(role: .user, body: "q"), Turn(role: .assistant, body: "a", reasoning: "original notes")]
        let text = ConversationRenderer.render(conversation(turns))
        let edited = text.replacingOccurrences(of: "original notes", with: "my own notes")
        XCTAssertEqual(IncrementalSave.decide(existing: edited, incoming: conversation(turns + [q2])), .writeAlongside)
    }

    func testEditingTheTitleAloneStillAllowsAppend() {
        // The H1 is cosmetic and is excluded from the body hash, so renaming a
        // thread does not strand it as a new file on every save.
        let text = ConversationRenderer.render(conversation([q1, a1], title: "Old title"))
        let incoming = conversation([q1, a1, q2], title: "New title")
        XCTAssertEqual(IncrementalSave.decide(existing: text, incoming: incoming), .append(turns: [q2]))
    }
}

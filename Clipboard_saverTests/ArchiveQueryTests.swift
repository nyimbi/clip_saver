import Foundation
import XCTest
@testable import Clipboard_saver

final class FTSQueryTests: XCTestCase {


    /// FTS5 treats these as operators. Unescaped, they are a *syntax error*,
    /// which SQLite reports as zero rows — indistinguishable from "nothing
    /// matched". That is the most misleading failure available, and a user
    /// searching for `C#` or a quoted phrase would hit it constantly.
    func testEveryTokenIsQuoted() throws {
        let query = try FTSQuery(raw: "hello world")
        XCTAssertEqual(query.raw, "\"hello\" \"world\"")
    }

    func testReservedWordsAreQuoted() throws {
        let query = try FTSQuery(raw: "AND OR NOT")
        XCTAssertEqual(query.raw, "\"AND\" \"OR\" \"NOT\"")
    }

    /// The case that motivates the whole type: a C# developer searching for a
    /// type name, and a user pasting a URL or a shell command.
    ///
    /// The assertion is that every token is a single balanced quoted string, not
    /// that certain characters are absent — a colon *inside* a quoted token is
    /// harmless, which is why checking for the bare character was the wrong test.
    func testSyntaxCharactersDoNotBreakTheQuery() throws {
        for raw in [
            "C#",
            "async/await",
            "what: why",
            "foo(bar)",
            "a - b",
            "100%",
            "key=value",
            "~/path/to/file",
            "NOT AND OR",
        ] {
            let query = try FTSQuery(raw: raw)
            for token in query.raw.split(separator: " ") {
                XCTAssertTrue(token.hasPrefix("\""), "unquoted token in \(raw): \(query.raw)")
                XCTAssertTrue(token.hasSuffix("\""), "unquoted token in \(raw): \(query.raw)")
            }
        }
    }

    /// Quotes are stripped as separators rather than escaped. Doubling them
    /// produces a token that FTS5 reads as one word containing a quote, which
    /// matches nothing — worse than treating them as the delimiters they are.
    func testQuotesSeparateTokens() throws {
        let query = try FTSQuery(raw: "say \"hello\"")
        XCTAssertEqual(query.raw, "\"say\" \"hello\"")
    }

    /// A trailing `*` is the one piece of real FTS syntax worth keeping: prefix
    /// search is genuinely useful for a half-remembered word.
    func testPrefixSearchIsPreserved() throws {
        XCTAssertEqual(try FTSQuery(raw: "actor*").raw, "\"actor*\"")
    }

    func testMixedPrefixAndExact() throws {
        XCTAssertEqual(try FTSQuery(raw: "actor* running").raw, "\"actor*\" \"running\"")
    }

    func testWhitespaceIsCollapsed() throws {
        XCTAssertEqual(try FTSQuery(raw: "  a   b  ").raw, "\"a\" \"b\"")
    }

    func testNewlinesSeparateTokens() throws {
        XCTAssertEqual(try FTSQuery(raw: "a\nb").raw, "\"a\" \"b\"")
    }

    func testEmptyQueryThrows() {
        XCTAssertThrowsError(try FTSQuery(raw: ""))
        XCTAssertThrowsError(try FTSQuery(raw: "   \n  "))
        XCTAssertThrowsError(try FTSQuery(raw: "\"\"\""))
    }

    /// The whole point: a query full of operators must still run. Executed
    /// against a real index rather than merely asserted on the string, because
    /// "it looks quoted" and "SQLite accepts it" are different claims.
    func testAwkwardQueriesExecuteWithoutError() throws {
        let store = try ArchiveStore(inMemory: true)
        let conversation = Conversation(
            title: "T", source: .claude,
            turns: [Turn(role: .user, body: "C# async/await what: why (parenthetical) 100% key=value")]
        )
        let rendered = ConversationRenderer.render(conversation)
        try store.index(
            parsed: ConversationRenderer.parse(from: rendered),
            atPath: "/tmp/q.md",
            metadata: DocumentMetadata(title: "T", platform: "Claude")
        )

        for query in ["C#", "what: why", "100%", "a - b", "async/await", "\"unbalanced"] {
            XCTAssertNoThrow(try store.search(query), "query failed: \(query)")
        }
        XCTAssertEqual(try store.search("C#").count, 1)
    }

    /// An unbalanced quote is what a user pasting a snippet actually types. It
    /// must not silently return nothing.
    func testUnbalancedQuoteStillFindsText() throws {
        let store = try ArchiveStore(inMemory: true)
        let conversation = Conversation(title: "T", source: .claude, turns: [Turn(role: .user, body: "unbalanced marker")])
        try store.index(
            parsed: ConversationRenderer.parse(from: ConversationRenderer.render(conversation)),
            atPath: "/tmp/q.md",
            metadata: DocumentMetadata(title: "T", platform: "Claude")
        )
        XCTAssertEqual(try store.search("\"unbalanced").count, 1)
    }
}

final class ContentTaggerTests: XCTestCase {

    private func tags(_ body: String, toolCalls: [ToolCall] = [], reasoning: String? = nil) -> [String] {
        ContentTagger.tags(
            for: Conversation(
                title: nil, source: .claude,
                turns: [Turn(role: .assistant, body: body, reasoning: reasoning, toolCalls: toolCalls)]
            )
        )
    }

    func testFencedCodeIsTagged() {
        XCTAssertTrue(tags("```swift\nlet x = 1\n```").contains("code"))
    }

    func testTildeFenceCountsAsCode() {
        XCTAssertTrue(tags("~~~\nplain\n~~~").contains("code"))
    }

    func testProseIsNotTaggedAsCode() {
        XCTAssertFalse(tags("just a sentence about code").contains("code"))
    }

    func testLanguageIsDetected() {
        XCTAssertTrue(tags("```python\nprint(1)\n```").contains("python"))
    }

    func testSeveralLanguagesAreAllTagged() {
        let found = tags("```swift\n1\n```\n\n```rust\n2\n```")
        XCTAssertTrue(found.contains("swift"))
        XCTAssertTrue(found.contains("rust"))
    }

    /// A fence with no language says only that there is code, not which kind.
    /// Claiming a language that is not in the fence would be a guess.
    func testUnlabelledFenceTagsNoLanguage() {
        let found = tags("```\nsome code\n```")
        XCTAssertTrue(found.contains("code"))
        XCTAssertEqual(found.filter { ContentTagger.knownLanguages.contains($0) }, [])
    }

    func testUnknownLanguageIsIgnored() {
        let found = tags("```brainfuck\n+++++\n```")
        XCTAssertTrue(found.contains("code"))
        XCTAssertFalse(found.contains("brainfuck"))
    }

    func testTableIsTagged() {
        XCTAssertTrue(tags("| a | b |\n|---|---|\n| 1 | 2 |").contains("table"))
    }

    func testPipeInProseIsNotATable() {
        XCTAssertFalse(tags("use foo | bar in a shell pipe").contains("table"))
    }

    func testToolCallsAreTagged() {
        XCTAssertTrue(tags("done", toolCalls: [ToolCall(name: "search")]).contains("tools"))
    }

    func testReasoningIsTagged() {
        XCTAssertTrue(tags("answer", reasoning: "thoughts").contains("reasoning"))
    }

    func testImageIsTagged() {
        XCTAssertTrue(tags("![alt](image.png)").contains("image"))
    }

    func testMathIsTagged() {
        XCTAssertTrue(tags("the value $x$ here").contains("math"))
    }

    func testConversationIsAlwaysTagged() {
        XCTAssertTrue(tags("anything").contains("conversation"))
    }

    func testEmptyConversationHasNoConversationTag() {
        XCTAssertFalse(
            ContentTagger.tags(for: Conversation(title: nil, source: .claude, turns: [])).contains("conversation")
        )
    }

    func testTagsAreLowercaseAndSorted() {
        let found = tags("```Swift\n1\n```")
        XCTAssertEqual(found, found.sorted())
        XCTAssertTrue(found.allSatisfy { $0 == $0.lowercased() })
    }

    func testNoDuplicateTags() {
        let found = tags("```swift\n1\n```\n\n```swift\n2\n```")
        XCTAssertEqual(Set(found).count, found.count)
    }

    func testVeryLongContentIsTaggedLong() {
        XCTAssertTrue(tags(String(repeating: "word ", count: 6000)).contains("long"))
    }
}

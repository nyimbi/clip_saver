import Foundation
import XCTest
@testable import Clipboard_saver

/// Tests for the request/response contract.
///
/// Split from the transport on purpose: the whole protocol has to be testable
/// without a process, a pipe, or a browser, and the transport is the only part
/// that needs one.
final class BridgeHandlerTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func conversation(title: String = "Thread", turns: [Turn]? = nil) -> Conversation {
        Conversation(
            title: title,
            source: .claude,
            model: "claude-opus-5",
            url: URL(string: "https://claude.ai/chat/abc"),
            turns: turns ?? [Turn(role: .user, body: "question"), Turn(role: .assistant, body: "answer")]
        )
    }

    private func saveRequest(
        _ conversation: Conversation? = nil,
        destination: String? = nil,
        behaviour: BridgeRequest.Behaviour = .auto,
        version: Int = BridgeHandler.currentVersion,
        id: String = "req-1"
    ) -> BridgeRequest {
        BridgeRequest(
            version: version, id: id, action: .saveConversation,
            conversation: conversation, destination: destination,
            behaviour: behaviour, query: nil
        )
    }

    private func handler(ask: Bool = false) -> BridgeHandler {
        BridgeHandler()
    }

    // MARK: - Version negotiation

    /// An extension left installed after a host upgrade is the normal case, and
    /// a version mismatch has to be a clear refusal. Parsing a newer payload
    /// with an older schema and writing the result to disk is the failure this
    /// prevents.
    func testMismatchedVersionIsRefusedAndNotRecoverable() {
        let response = BridgeHandler().handle(saveRequest(conversation(), destination: folder.path, version: 99))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unsupportedVersion)
        XCTAssertEqual(response.error?.recoverable, false, "retrying cannot fix a version mismatch")
    }

    func testMismatchedVersionWritesNothing() {
        _ = BridgeHandler().handle(saveRequest(conversation(), destination: folder.path, version: 99))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertTrue(files.isEmpty, "a refused request must not write: \(files)")
    }

    func testCurrentVersionIsAccepted() {
        let response = BridgeHandler().handle(saveRequest(conversation(), destination: folder.path))
        XCTAssertTrue(response.ok)
    }

    // MARK: - Malformed requests

    func testMissingIdIsRefused() {
        var request = saveRequest(conversation(), destination: folder.path)
        request.id = ""
        let response = BridgeHandler().handle(request)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .malformedRequest)
    }

    func testSaveWithoutAConversationIsRefused() {
        let response = BridgeHandler().handle(saveRequest(nil, destination: folder.path))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .malformedRequest)
    }

    func testSearchWithoutAQueryIsRefused() {
        let request = BridgeRequest(
            version: BridgeHandler.currentVersion, id: "q", action: .searchArchive,
            conversation: nil, destination: nil, behaviour: nil, query: "   "
        )
        let response = BridgeHandler().handle(request)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .malformedRequest)
    }

    /// Every failure comes back as a response. A port that dies mid-request
    /// surfaces in the extension as a generic "An unexpected error occurred",
    /// which is useless for diagnosing a selector that stopped matching.
    func testHandlerNeverThrows() {
        let malformed = [
            saveRequest(nil),
            saveRequest(conversation(), destination: "/no/such/folder/exists"),
        ]
        for request in malformed {
            XCTAssertNoThrow(BridgeHandler().handle(request))
        }
    }

    // MARK: - Saving

    func testAutoBehaviourWritesWithoutPrompting() throws {
        let response = BridgeHandler().handle(
            saveRequest(conversation(title: "Swift concurrency"), destination: folder.path, behaviour: .auto)
        )
        XCTAssertTrue(response.ok)
        let path = try XCTUnwrap(response.result?.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testFilenameComesFromTheConversationTitle() throws {
        let response = BridgeHandler().handle(
            saveRequest(conversation(title: "Structured concurrency"), destination: folder.path, behaviour: .auto)
        )
        let name = try XCTUnwrap(response.result?.path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
        XCTAssertTrue(name.contains("Structured concurrency"), "got \(name)")
    }

    func testResultReportsTheTurnCount() throws {
        let turns = (0..<5).map { Turn(role: .user, body: "turn \($0)") }
        let response = BridgeHandler().handle(
            saveRequest(conversation(turns: turns), destination: folder.path, behaviour: .auto)
        )
        XCTAssertEqual(response.result?.turns, 5)
    }

    func testResultReportsTheAction() throws {
        let response = BridgeHandler().handle(saveRequest(conversation(), destination: folder.path))
        XCTAssertEqual(response.result?.action, "writeNew")
    }

    /// A second save of the same conversation must extend the file rather than
    /// create another one. This is the behaviour that stops the archive becoming
    /// fourteen copies of one thread.
    func testSecondSaveOfTheSameConversationAppends() throws {
        let handler = BridgeHandler()
        _ = handler.handle(saveRequest(conversation(), destination: folder.path))
        let second = handler.handle(saveRequest(conversation(), destination: folder.path))
        XCTAssertEqual(second.result?.action, "unchanged")

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1, "a repeated save must not create a second file")
    }

    func testGrownConversationAppendsTheNewTurns() throws {
        let handler = BridgeHandler()
        _ = handler.handle(saveRequest(conversation(turns: [Turn(role: .user, body: "first")]), destination: folder.path))

        let grown = conversation(turns: [
            Turn(role: .user, body: "first"),
            Turn(role: .assistant, body: "second"),
        ])
        let response = handler.handle(saveRequest(grown, destination: folder.path))
        XCTAssertEqual(response.result?.action, "append")

        let path = try XCTUnwrap(response.result?.path)
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        XCTAssertTrue(text.contains("second"))
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: folder.path)).count, 1)
    }

    // MARK: - One thread, one file

    /// The behaviour the whole incremental design exists to produce, asserted as
    /// a sequence rather than as a pair of calls. It was broken in three
    /// successive ways while this was built, and each break only showed up
    /// across saves — a single-save test passes every one of them.
    func testAThreadSavesRepeatedlyAndNeverDuplicates() throws {
        let handler = BridgeHandler()
        let base = [
            Turn(role: .user, body: "question"),
            Turn(role: .assistant, body: "answer"),
        ]

        func save(_ turns: [Turn]) -> BridgeResponse {
            handler.handle(saveRequest(conversation(turns: turns), destination: folder.path))
        }

        XCTAssertEqual(save(base).result?.action, "writeNew")
        XCTAssertEqual(save(base).result?.action, "unchanged")
        XCTAssertEqual(save(base + [Turn(role: .user, body: "third")]).result?.action, "append")
        XCTAssertEqual(save(base + [Turn(role: .user, body: "third"), Turn(role: .assistant, body: "fourth")]).result?.action, "append")
        XCTAssertEqual(save(base + [Turn(role: .user, body: "third"), Turn(role: .assistant, body: "fourth")]).result?.action, "unchanged")

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1, "one thread must stay one file, got \(files.sorted())")
    }

    /// A grown thread has a different fingerprint from the one on disk, so
    /// matching on equality alone produced a new file on every continuation.
    func testContinuedThreadUpdatesTheOriginalFile() throws {
        let handler = BridgeHandler()
        let first = [Turn(role: .user, body: "question"), Turn(role: .assistant, body: "answer")]

        let original = try XCTUnwrap(
            handler.handle(saveRequest(conversation(turns: first), destination: folder.path)).result?.path
        )
        let grown = handler.handle(
            saveRequest(conversation(turns: first + [Turn(role: .user, body: "third")]), destination: folder.path)
        )

        XCTAssertEqual(grown.result?.path, original, "the original file must be updated in place")
        let text = try String(contentsOf: URL(fileURLWithPath: original), encoding: .utf8)
        XCTAssertTrue(text.contains("third"))
    }

    /// `unchanged` must not rewrite the file. Churning the mtime wakes every
    /// watcher on the folder for bytes that are already correct.
    func testUnchangedDoesNotTouchTheFile() throws {
        let handler = BridgeHandler()
        let turns = [Turn(role: .user, body: "question"), Turn(role: .assistant, body: "answer")]
        let path = try XCTUnwrap(
            handler.handle(saveRequest(conversation(turns: turns), destination: folder.path)).result?.path
        )
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date

        Thread.sleep(forTimeInterval: 1.1)
        _ = handler.handle(saveRequest(conversation(turns: turns), destination: folder.path))

        let after = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "an unchanged re-save must not modify the file")
    }

    // MARK: - Hand-edited files

    /// A hand-edited file stops matching on content, because the edit is exactly
    /// what the comparison inspects. Without recognising it, the file looks like
    /// a conversation that was never saved and the user gets a silent duplicate.
    func testHandEditedFileIsPreservedAndReportedAsAlongside() throws {
        let handler = BridgeHandler()
        let turns = [
            Turn(role: .user, body: "question"),
            Turn(role: .assistant, body: "answer"),
            Turn(role: .user, body: "third"),
            Turn(role: .assistant, body: "fourth"),
        ]
        let path = try XCTUnwrap(
            handler.handle(saveRequest(conversation(turns: turns), destination: folder.path)).result?.path
        )

        let edited = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            .replacingOccurrences(of: "fourth", with: "fourth, EDITED BY HAND")
        try edited.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)

        let response = handler.handle(saveRequest(conversation(turns: turns), destination: folder.path))
        XCTAssertEqual(response.result?.action, "writeAlongside")

        let onDisk = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("EDITED BY HAND"), "the user's edit must survive")
    }

    func testASecondHandEditedSaveDoesNotOverwriteEitherFile() throws {
        let handler = BridgeHandler()
        let turns = [
            Turn(role: .user, body: "question"),
            Turn(role: .assistant, body: "answer"),
            Turn(role: .user, body: "third"),
            Turn(role: .assistant, body: "fourth"),
        ]
        let path = try XCTUnwrap(
            handler.handle(saveRequest(conversation(turns: turns), destination: folder.path)).result?.path
        )
        for marker in ["EDIT ONE", "EDIT TWO"] {
            let edited = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
                .replacingOccurrences(of: "fourth", with: "fourth, \(marker)")
            try edited.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            _ = handler.handle(saveRequest(conversation(turns: turns), destination: folder.path))
        }
        // The original keeps the last edit; the duplicates do not clobber it.
        XCTAssertTrue(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8).contains("EDIT TWO"))
    }

    /// A different thread on the same platform must not be mistaken for an
    /// edited copy of an existing one.
    func testUnrelatedThreadGetsItsOwnFile() throws {
        let handler = BridgeHandler()
        _ = handler.handle(
            saveRequest(conversation(turns: [Turn(role: .user, body: "q"), Turn(role: .assistant, body: "a")]), destination: folder.path)
        )
        let other = Conversation(
            title: "Other", source: .claude, model: "claude-opus-5",
            turns: [Turn(role: .user, body: "completely different question")]
        )
        let response = handler.handle(saveRequest(other, destination: folder.path))
        XCTAssertEqual(response.result?.action, "writeNew")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }

    /// Same platform, same model, same length, different content — the case a
    /// fuzzy "is it an edited copy" check must not swallow.
    func testSameLengthDifferentContentIsNotTreatedAsAnEdit() throws {
        let handler = BridgeHandler()
        _ = handler.handle(
            saveRequest(conversation(turns: [
                Turn(role: .user, body: "question one"),
                Turn(role: .assistant, body: "answer one"),
            ]), destination: folder.path)
        )
        let unrelated = conversation(turns: [
            Turn(role: .user, body: "question two"),
            Turn(role: .assistant, body: "answer two"),
        ])
        let response = handler.handle(saveRequest(unrelated, destination: folder.path))
        XCTAssertEqual(response.result?.action, "writeNew")
    }

    // MARK: - The trust boundary

    /// The extension names its own destination, and it is a separate process
    /// with its own privileges. A path that does not exist must be refused
    /// rather than created.
    func testNonexistentDestinationIsRefusedAndNothingIsCreated() {
        let missing = folder.appendingPathComponent("not-created/deeper").path
        let response = BridgeHandler().handle(saveRequest(conversation(), destination: missing))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unwritableDestination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    func testDestinationThatIsAFileIsRefused() throws {
        let file = folder.appendingPathComponent("a-file.md")
        try Data("x".utf8).write(to: file)
        let response = BridgeHandler().handle(saveRequest(conversation(), destination: file.path))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unwritableDestination)
    }

    func testTildeInDestinationIsExpanded() throws {
        // The extension may send `~/Documents`, which must not be treated as a
        // literal directory named "~".
        let response = BridgeHandler().handle(saveRequest(conversation(), destination: "~/"))
        // Either the home directory is writable (save succeeds) or it is not
        // (refused). What must not happen is a literal "~" path being created.
        if response.ok {
            let path = try XCTUnwrap(response.result?.path)
            XCTAssertFalse(path.contains("/~/"), "tilde was not expanded: \(path)")
        } else {
            XCTAssertEqual(response.error?.code, .unwritableDestination)
        }
    }

    /// With no destination given, the host falls back to the configured folder.
    ///
    /// Asserted against the resolved path rather than a fixed error code,
    /// because whether a default folder exists depends on the machine running
    /// the test. What must hold on every machine is that the outcome is
    /// structured: a save or a typed failure, never a crash.
    /// With no destination given, the host falls back to the configured folder.
    ///
    /// The default folder is a path that may not exist, and this tool will not
    /// create one the user did not ask for, so the legitimate outcomes are
    /// "saved into the configured folder" and "no destination configured". Both
    /// are asserted; an unwritable *existing* default would be a bug.
    func testEmptyDestinationFallsBackToTheConfiguredFolder() throws {
        let response = BridgeHandler().handle(saveRequest(conversation(), destination: nil))

        if response.ok {
            let path = try XCTUnwrap(response.result?.path)
            let expected = try XCTUnwrap(SearchService.folders().first?.standardizedFileURL.path)
            XCTAssertTrue(
                path.hasPrefix(expected),
                "expected the write to land in the configured folder \(expected), got \(path)"
            )
            addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        } else {
            XCTAssertEqual(
                response.error?.code, .noDestination,
                "a missing default folder is 'not configured', not 'unwritable'"
            )
            XCTAssertEqual(response.error?.recoverable, true)
        }
    }

    /// A destination that exists but is not writable is the permission-denied
    /// case, which is distinct from "not found" and is worth telling apart.
    func testUnwritableExistingFolderIsRefused() throws {
        let locked = folder.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }

        // Root can write anywhere, so this asserts the code path only where the
        // restriction is actually enforceable.
        try XCTSkipUnless(FileManager.default.isWritableFile(atPath: locked.path) == false,
                          "cannot make a directory unwritable as this user")

        let response = BridgeHandler().handle(saveRequest(conversation(), destination: locked.path))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unwritableDestination)
        XCTAssertEqual(response.error?.recoverable, true)
    }

    // MARK: - Incomplete captures

    /// The flag is advisory from the extension's side. The host reports what it
    /// received, and the case that matters is a truncated capture written as if
    /// it were whole.
    func testIncompleteCaptureIsReportedBack() throws {
        let partial = Conversation(
            title: "Truncated", source: .claude,
            turns: [Turn(role: .user, body: "q")],
            confidence: ExtractionConfidence(score: 0.3, complete: false, strategy: .dom, warnings: ["only 3 of 40 turns"])
        )
        let response = BridgeHandler().handle(saveRequest(partial, destination: folder.path))
        XCTAssertEqual(response.result?.complete, false)
        XCTAssertEqual(response.result?.confidence ?? 1, 0.3, accuracy: 0.001)
        XCTAssertEqual(response.result?.incompleteReason, "only 3 of 40 turns")
    }

    func testCompleteCaptureIsReportedBack() {
        let good = Conversation(
            title: "Fine", source: .claude,
            turns: [Turn(role: .user, body: "q")],
            confidence: ExtractionConfidence(score: 0.99, complete: true, strategy: .state)
        )
        let response = BridgeHandler().handle(saveRequest(good, destination: folder.path))
        XCTAssertEqual(response.result?.complete, true)
        XCTAssertNil(response.result?.incompleteReason)
    }

    // MARK: - Search

    func testSearchReturnsMarkdown() {
        let request = BridgeRequest(
            version: BridgeHandler.currentVersion, id: "q1", action: .searchArchive,
            conversation: nil, destination: nil, behaviour: nil, query: "actors"
        )
        let response = BridgeHandler().handle(request)
        XCTAssertTrue(response.ok)
        XCTAssertNotNil(response.search?.markdown)
        XCTAssertEqual(response.search?.query, "actors")
    }

    // MARK: - Round trip

    /// The wire form has to survive framing, or the extension receives something
    /// it cannot parse.
    func testRequestAndResponseSurviveTheWire() throws {
        let request = saveRequest(conversation(), destination: folder.path)
        let data = try NativeMessage.frame(json: request)
        let read = try XCTUnwrap(NativeMessage.read(from: data))
        let decoded = try NativeMessage.decode(read.payload, as: BridgeRequest.self)
        XCTAssertEqual(decoded.id, request.id)
        XCTAssertEqual(decoded.action, request.action)
        XCTAssertEqual(decoded.conversation?.turns.count, request.conversation?.turns.count)

        let response = BridgeHandler().handle(decoded)
        let responseData = try NativeMessage.frame(json: response)
        let responseRead = try XCTUnwrap(NativeMessage.read(from: responseData))
        let back = try NativeMessage.decode(responseRead.payload, as: BridgeResponse.self)
        XCTAssertEqual(back.id, request.id, "the id must be echoed so a port can match responses")
        XCTAssertTrue(back.ok)
    }

    /// An action this build does not know must reach the handler as a
    /// structured refusal, not a decoding crash. A newer extension sending an
    /// action added after this build is the expected case, and the extension
    /// gets a message it can act on instead of a dead port.
    func testUnknownActionIsRefusedRatherThanFailingToDecode() {
        let json = #"{"version":1,"id":"x","action":"somethingNew"}"#
        let data = Data(json.utf8)

        // The strict decoder rejects it, which is the correct first line of
        // defence.
        XCTAssertThrowsError(try JSONDecoder().decode(BridgeRequest.self, from: data))

        // And the transport must turn that into a protocol-level failure, not
        // let it escape. This is the path a real host takes.
        let response = BridgeHandler().handleUndecodable(data, id: "x")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .malformedRequest)
        XCTAssertEqual(response.id, "x", "the id must be echoed so the extension can match the failure")
    }

    func testResponseCarriesTheVersion() {
        let response = BridgeHandler().handle(saveRequest(conversation(), destination: folder.path))
        XCTAssertEqual(response.version, BridgeHandler.currentVersion)
    }
}

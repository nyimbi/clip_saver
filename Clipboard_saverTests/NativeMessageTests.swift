import Foundation
import XCTest
@testable import Clipboard_saver

/// Tests for the native messaging framing.
///
/// Framing is where a protocol fails invisibly: a mis-framed message either
/// hangs the host or is silently dropped, and both look like "the extension
/// sometimes does not work".
final class NativeMessageTests: XCTestCase {

    // MARK: - Framing

    func testFrameProducesAFourByteLengthPrefix() throws {
        let framed = NativeMessage.frame(Data("hello".utf8))
        let declared = framed.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
        XCTAssertEqual(declared, 5)
        XCTAssertEqual(framed.count, 9)
        XCTAssertEqual(framed.suffix(5), Data("hello".utf8))
    }

    /// The length prefix is little-endian per the specification. Getting this
    /// wrong on one side produces a plausible-looking but wrong length.
    func testLengthPrefixIsLittleEndian() {
        let framed = NativeMessage.frame(Data(repeating: 0, count: 258))
        XCTAssertEqual(Array(framed.prefix(4)), [0x02, 0x01, 0x00, 0x00])
    }

    func testFrameRoundTrips() throws {
        let payload = Data("the quick brown fox".utf8)
        let read = try XCTUnwrap(NativeMessage.read(from: NativeMessage.frame(payload)))
        XCTAssertEqual(read.payload, payload)
        XCTAssertEqual(read.consumed, payload.count + 4)
    }

    // MARK: - The reason for length framing

    /// A Markdown conversation is thousands of newlines long. Newline framing
    /// would split this into thousands of malformed messages.
    func testPayloadContainingManyNewlinesSurvives() throws {
        let body = String(repeating: "## User\n\nsome text\n\n", count: 500)
        let framed = NativeMessage.frame(Data(body.utf8))
        let read = try XCTUnwrap(NativeMessage.read(from: framed))
        XCTAssertEqual(String(decoding: read.payload, as: UTF8.self), body)
    }

    /// Two messages back to back, as a pipelined port delivers them.
    ///
    /// The remainder is deliberately left as a `dropFirst` slice rather than
    /// re-wrapped. `Data` slices do not start at index zero, and reading a
    /// length prefix out of one with zero-based offsets silently reads the wrong
    /// four bytes — which is what a real stdio loop does on every message after
    /// the first, so the failure mode has to be pinned down by a test rather
    /// than remembered.
    func testTwoMessagesInOneBufferAreReadSeparately() throws {
        var buffer = NativeMessage.frame(Data(#"{"id":"a"}"#.utf8))
        buffer.append(NativeMessage.frame(Data(#"{"id":"bb"}"#.utf8)))

        let first = try XCTUnwrap(NativeMessage.read(from: buffer))
        XCTAssertEqual(String(decoding: first.payload, as: UTF8.self), #"{"id":"a"}"#)

        let remainder = buffer.dropFirst(first.consumed)
        let second = try XCTUnwrap(NativeMessage.read(from: remainder))
        XCTAssertEqual(String(decoding: second.payload, as: UTF8.self), #"{"id":"bb"}"#)
    }

    /// Three messages, so the slice is consumed twice and the indices are
    /// genuinely non-zero on the second read.
    func testThreeMessagesInOneBuffer() throws {
        var buffer = Data()
        for id in ["one", "two", "three"] {
            buffer.append(NativeMessage.frame(Data(#"{"id":"\#(id)"}"#.utf8)))
        }

        var seen: [String] = []
        while let message = try NativeMessage.read(from: buffer) {
            seen.append(String(decoding: message.payload, as: UTF8.self))
            buffer = Data(buffer.dropFirst(message.consumed))
        }
        XCTAssertEqual(seen, [#"{"id":"one"}"#, #"{"id":"two"}"#, #"{"id":"three"}"#])
    }

    func testUnicodePayloadIsMeasuredInBytesNotCharacters() throws {
        // Four bytes per emoji. A length counted in characters would understate
        // the payload and truncate it.
        let payload = Data("🙂🙂".utf8)
        let framed = NativeMessage.frame(payload)
        let read = try XCTUnwrap(NativeMessage.read(from: framed))
        XCTAssertEqual(read.payload, payload)
        XCTAssertEqual(payload.count, 8)
    }

    // MARK: - Truncated input

    /// A partial read is a normal state for a stream, not an error. The caller
    /// waits for more bytes rather than treating this as a protocol failure.
    func testEmptyBufferReadsAsEndOfStream() throws {
        XCTAssertNil(try NativeMessage.read(from: Data()))
    }

    func testPartialHeaderIsReported() {
        XCTAssertThrowsError(try NativeMessage.read(from: Data([0x01, 0x02])))
    }

    func testPartialPayloadIsReported() {
        var framed = NativeMessage.frame(Data(repeating: 0x41, count: 100))
        framed = framed.prefix(50)
        XCTAssertThrowsError(try NativeMessage.read(from: framed)) { error in
            guard case NativeMessage.Failure.incompletePayload = error else {
                return XCTFail("expected incompletePayload, got \(error)")
            }
        }
    }

    /// A corrupt length prefix must not make us allocate whatever it claims.
    func testOversizedLengthPrefixIsRefused() {
        var header = UInt32(NativeMessage.maximumMessageSize + 1).littleEndian
        let data = withUnsafeBytes(of: &header) { Data($0) }
        XCTAssertThrowsError(try NativeMessage.read(from: data)) { error in
            guard case NativeMessage.Failure.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }

    func testZeroLengthIsRefused() {
        var header = UInt32(0).littleEndian
        let data = withUnsafeBytes(of: &header) { Data($0) }
        XCTAssertThrowsError(try NativeMessage.read(from: data))
    }

    /// A realistic worst case: a long conversation with code blocks, which is
    /// what a real capture looks like on the wire.
    func testLargeRealisticConversationFrames() throws {
        let turn = """
            ## Assistant

            ```swift
            await withTaskGroup(of: Int.self) { group in
                for i in 1...3 { group.addTask { await work(i) } }
            }
            ```

            | Approach | Waits for |
            |---|---|
            | `async let` | fixed set |

            """
        let payload = Data(String(repeating: turn, count: 500).utf8)
        let read = try XCTUnwrap(NativeMessage.read(from: NativeMessage.frame(payload)))
        XCTAssertEqual(read.payload.count, payload.count)
    }

    // MARK: - JSON

    func testJSONRoundTripsThroughFraming() throws {
        struct Payload: Codable, Equatable { var id: String; var count: Int }
        let original = Payload(id: "abc", count: 42)
        let data = try NativeMessage.frame(json: original)
        let read = try XCTUnwrap(NativeMessage.read(from: data))
        XCTAssertEqual(try NativeMessage.decode(read.payload, as: Payload.self), original)
    }

    func testDecodingInvalidJSONThrows() {
        XCTAssertThrowsError(try NativeMessage.decode(Data("not json".utf8), as: [String: String].self))
    }
}

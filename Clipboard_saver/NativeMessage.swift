import Foundation

/// Length-prefixed framing for Chrome native messaging.
///
/// The alternative is newline framing, and it is wrong for this payload: a
/// Markdown conversation is thousands of newlines long, so a delimiter that
/// appears inside the data will split one message into two malformed ones. The
/// length prefix makes the framing self-describing, which is what the native
/// messaging specification requires.
enum NativeMessage {

    /// Chrome's ceiling for a single runtime message. Enforced on read as well
    /// as write, because a corrupt or hostile length prefix would otherwise ask
    /// us to allocate whatever it claimed.
    static let maximumMessageSize = 512 * 1024 * 1024

    enum Failure: Error, CustomStringConvertible {
        case incompleteHeader
        case incompletePayload(expected: Int, got: Int)
        case tooLarge(Int)
        case notAnObject

        var description: String {
            switch self {
            case .incompleteHeader:
                return "The message ended before its length prefix was complete."
            case .incompletePayload(let expected, let got):
                return "Expected \(expected) bytes of payload, got \(got)."
            case .tooLarge(let size):
                return "Message of \(size) bytes exceeds the \(maximumMessageSize) byte limit."
            case .notAnObject:
                return "A message must be a JSON object."
            }
        }
    }

    /// Reads one message from `data`, or `nil` at a clean end of stream.
    ///
    /// `data` may be a slice whose indices do not start at zero — which is
    /// exactly what a stdio loop has after consuming the bytes of a previous
    /// message. All offsets are therefore computed from `startIndex` rather than
    /// from zero; `Data.prefix` and `subdata(in:)` both take indices relative to
    /// the view's own start, and assuming zero would read the wrong four bytes
    /// and declare a nonsense length.
    ///
    /// - Returns: the payload and how many bytes it consumed, or `nil` at a
    ///   clean end of stream.
    static func read(from data: Data) throws -> (payload: Data, consumed: Int)? {
        let headerSize = 4
        guard data.count >= headerSize else {
            if data.isEmpty { return nil }
            throw Failure.incompleteHeader
        }

        let start = data.startIndex
        let declared = data[start..<(start + headerSize)].withUnsafeBytes { raw in
            Int(raw.loadUnaligned(as: UInt32.self).littleEndian)
        }
        guard declared <= maximumMessageSize else { throw Failure.tooLarge(declared) }
        guard declared > 0 else { throw Failure.notAnObject }

        let available = data.count - headerSize
        guard available >= declared else {
            throw Failure.incompletePayload(expected: declared, got: available)
        }

        let payload = data.subdata(in: (start + headerSize)..<(start + headerSize + declared))
        return (payload, headerSize + declared)
    }

    /// Frames a payload for writing.
    static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: 4 + payload.count)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static func frame(json: some Encodable) throws -> Data {
        frame(try encoder().encode(json))
    }

    /// Decodes a payload as JSON.
    static func decode<T: Decodable>(_ payload: Data, as type: T.Type) throws -> T {
        try decoder().decode(type, from: payload)
    }

    /// ISO-8601 on the wire.
    ///
    /// Swift's default is a Double of seconds since 2001, which is unambiguous to
    /// Swift and to nobody else. A JavaScript sender reading that has to know the
    /// reference date to subtract it, and a human reading a captured payload has
    /// to recognise it at all. ISO-8601 costs a few bytes and is the one format
    /// both sides already parse.
    ///
    /// There are no deployed senders, so this is free to fix now and expensive to
    /// fix after a store release.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

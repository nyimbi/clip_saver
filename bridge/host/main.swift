import Foundation

/// The native messaging host.
///
/// A *separate binary* from the Services app, deliberately. Chrome launches a
/// native messaging host directly, with no GUI session, on a pipe — and the
/// Services app is an `LSUIElement` agent whose whole reason to exist is to be
/// driven by Finder. Making that binary serve both roles would mean it either
/// initialises AppKit when nothing is there to interact with, or exits when the
/// browser starts a conversation. So it is its own executable, sharing the
/// conversion and archive code by compiling the same sources.
///
/// Built by `bridge/host/build.sh` with `swiftc` rather than as an Xcode target:
/// the project uses objectVersion 77 synchronized folder groups, and adding a
/// target to that by hand is a good way to corrupt it for the sake of a
/// single-file target that needs no resources.

/// Reads framed messages from stdin until the stream ends.
func serve() {
    let handler = BridgeHandler()
    var buffer = Data()

    while true {
        // Drain whatever is readable. `read` returning 0 is a clean end of
        // stream: Chrome closed the port.
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = chunk.withUnsafeMutableBytes { pointer -> Int in
            Foundation.read(0, pointer.baseAddress, pointer.count)
        }

        if count == 0 { return }
        if count < 0 {
            if errno == EINTR { continue }
            return
        }
        buffer.append(contentsOf: chunk[0..<count])

        // A single read can carry several messages, or half of one. Loop until
        // the buffer does not begin with a complete frame.
        // A partial frame throws, which is the normal state while more bytes are
        // still arriving; the loop then exits and the next read continues it.
        while let message = try? NativeMessage.read(from: buffer) {
            buffer = Data(buffer.dropFirst(message.consumed))

            let response = respond(to: message.payload, handler: handler)
            write(response)
        }
    }
}

func respond(to payload: Data, handler: BridgeHandler) -> Data {
    do {
        let request = try NativeMessage.decode(payload, as: BridgeRequest.self)
        return encode(handler.handle(request))
    } catch {
        // The id is recovered from the raw JSON so the extension can still match
        // the failure to its request rather than seeing a dead port, and the
        // decoding error travels with it so the message can name the field.
        let id = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])??["id"] as? String ?? "unknown"
        return encode(handler.handleUndecodable(payload, id: id, underlying: error))
    }
}

func encode(_ response: BridgeResponse) -> Data {
    guard let framed = try? NativeMessage.frame(json: response) else {
        // Encoding our own response cannot realistically fail, but a host that
        // writes nothing leaves the extension waiting forever, so there is a
        // last-resort reply.
        let fallback = BridgeResponse(
            version: BridgeHandler.currentVersion, id: "unknown", ok: false,
            result: nil, search: nil,
            error: .init(code: .internalError, message: "The reply could not be encoded.", recoverable: true)
        )
        return (try? NativeMessage.frame(json: fallback)) ?? Data()
    }
    return framed
}

func write(_ data: Data) {
    data.withUnsafeBytes { pointer in
        var offset = 0
        while offset < pointer.count {
            let written = Foundation.write(1, pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
            if written <= 0 {
                if errno == EINTR { continue }
                return
            }
            offset += written
        }
    }
}

serve()

import Foundation

/// The wire contract between the browser extension and this app.
///
/// Defined in both languages against `bridge/PROTOCOL.md`, which is the
/// normative description. The version is checked on every message: an extension
/// left installed after a host upgrade is the common case, and a mismatch has to
/// be a clear refusal rather than a misparsed conversation written to disk.
struct BridgeRequest: Codable {
    enum Action: String, Codable {
        case saveConversation
        case searchArchive
    }

    /// How a destination is chosen.
    ///
    /// `ask` opens the save panel. `auto` derives the filename from the
    /// conversation's own title and writes without prompting, which is what the
    /// context menu uses — a right-click that then produces another dialog is two
    /// clicks, not one.
    enum Behaviour: String, Codable {
        case ask
        case auto
    }

    var version: Int
    var id: String
    var action: Action
    var conversation: Conversation?
    /// Present for `saveConversation` with `behaviour == "auto"`.
    var destination: String?
    var behaviour: Behaviour?
    /// Names one of the user's configured destinations. Takes precedence over
    /// `destination`, and an unknown name falls back rather than failing — an
    /// extension from a future build should still be able to save.
    var preset: String?
    /// Present for `searchArchive`.
    var query: String?
}

struct BridgeResponse: Codable {
    struct Failure: Codable {
        enum Code: String, Codable {
            case unsupportedVersion
            case malformedRequest
            case noDestination
            case unwritableDestination
            case extractionFailed
            case internalError
        }

        var code: Code
        var message: String
        /// `false` means retrying the same request cannot help, so the extension
        /// should not offer a Retry button.
        var recoverable: Bool
    }

    /// What a save actually did. Echoes the core's `SaveAction` so the
    /// extension can tell the user whether the file was new, extended, or
    /// written alongside because the existing one was hand-edited.
    struct SaveResult: Codable {
        var path: String?
        var action: String
        var turns: Int
        var confidence: Double
        var complete: Bool
        var incompleteReason: String?
    }

    struct SearchResult: Codable {
        var query: String
        var markdown: String
        var hits: Int
    }

    var version: Int
    var id: String
    var ok: Bool
    var result: SaveResult?
    var search: SearchResult?
    var error: Failure?
}

/// Handles requests. Split from the transport so the whole protocol can be
/// tested without a process, a pipe, or a browser.
struct BridgeHandler {

    /// The protocol version this build speaks.
    static let currentVersion = 1

    enum Failure: Error {
        case refusal(BridgeResponse.Failure)
    }

    /// Answers one request.
    ///
    /// Never throws for a protocol-level problem: every failure comes back as a
    /// response, because a native messaging port that dies mid-request surfaces
    /// in the extension as a generic "An unexpected error occurred", which is
    /// useless for diagnosing a selector that stopped matching.
    func handle(_ request: BridgeRequest) -> BridgeResponse {
        do {
            try validate(request)
            switch request.action {
            case .saveConversation: return save(request)
            case .searchArchive: return search(request)
            }
        } catch let Failure.refusal(failure) {
            return BridgeResponse(
                version: Self.currentVersion, id: request.id, ok: false,
                result: nil, search: nil, error: failure
            )
        } catch {
            return BridgeResponse(
                version: Self.currentVersion, id: request.id, ok: false,
                result: nil, search: nil,
                error: .init(code: .internalError, message: "\(error)", recoverable: true)
            )
        }
    }

    /// Answers a payload that could not be decoded into a `BridgeRequest`.
    ///
    /// A newer extension sending an action added after this build is the
    /// expected case, and the extension needs a response it can read rather than
    /// a dead port — a port that dies mid-request surfaces as a generic "An
    /// unexpected error occurred", which tells the user nothing about which half
    /// needs updating. The id is recovered from the raw JSON where possible so
    /// the extension can still match the failure to its request.
    func handleUndecodable(_ payload: Data, id fallbackID: String) -> BridgeResponse {
        let recovered = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])??["id"] as? String
        return BridgeResponse(
            version: Self.currentVersion,
            id: recovered ?? fallbackID,
            ok: false,
            result: nil,
            search: nil,
            error: .init(
                code: .malformedRequest,
                message: "This app could not read the request. It may come from a newer version of the extension.",
                recoverable: false
            )
        )
    }

    private func validate(_ request: BridgeRequest) throws {
        guard request.version == Self.currentVersion else {
            throw Failure.refusal(.init(
                code: .unsupportedVersion,
                message: "This app speaks protocol version \(Self.currentVersion), the extension sent \(request.version). Update whichever is older.",
                recoverable: false
            ))
        }
        guard !request.id.isEmpty else {
            throw Failure.refusal(.init(code: .malformedRequest, message: "A request needs an id.", recoverable: false))
        }
        switch request.action {
        case .saveConversation:
            guard request.conversation != nil else {
                throw Failure.refusal(.init(code: .malformedRequest, message: "saveConversation needs a conversation.", recoverable: false))
            }
        case .searchArchive:
            guard let query = request.query, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Failure.refusal(.init(code: .malformedRequest, message: "searchArchive needs a query.", recoverable: false))
            }
        }
    }

    // MARK: - Save

    private func save(_ request: BridgeRequest) -> BridgeResponse {
        guard let conversation = request.conversation else {
            return failure(request, .init(code: .malformedRequest, message: "No conversation.", recoverable: false))
        }

        do {
            let saver = ConversationSaver()
            let saved = try saver.save(
                conversation,
                destination: request.destination,
                behaviour: request.behaviour ?? .ask,
                preset: request.preset
            )
            let result = BridgeResponse.SaveResult(
                path: saved.path,
                action: saved.action,
                turns: saved.turns,
                confidence: saved.confidence,
                complete: saved.complete,
                incompleteReason: saved.incompleteReason
            )
            return BridgeResponse(
                version: Self.currentVersion, id: request.id, ok: true,
                result: result, search: nil, error: nil
            )
        } catch let error as ConversationSaver.Failure {
            return failure(request, error.asBridgeFailure)
        } catch {
            return failure(request, .init(code: .internalError, message: "\(error)", recoverable: true))
        }
    }

    // MARK: - Search

    private func search(_ request: BridgeRequest) -> BridgeResponse {
        guard let query = request.query else {
            return failure(request, .init(code: .malformedRequest, message: "No query.", recoverable: false))
        }
        let result = SearchService.search(query, folders: SearchService.folders())
        if let error = result.error {
            return failure(request, .init(code: .internalError, message: error, recoverable: true))
        }
        return BridgeResponse(
            version: Self.currentVersion, id: request.id, ok: true,
            result: nil,
            search: .init(query: query, markdown: result.markdown(), hits: result.hits.count),
            error: nil
        )
    }

    private func failure(_ request: BridgeRequest, _ error: BridgeResponse.Failure) -> BridgeResponse {
        BridgeResponse(
            version: Self.currentVersion, id: request.id, ok: false,
            result: nil, search: nil, error: error
        )
    }
}

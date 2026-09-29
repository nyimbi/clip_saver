import CryptoKit
import Foundation

/// A stable content identity for a conversation.
///
/// Dedup and incremental save both need to answer "have I seen this before?"
/// across process launches, and neither can afford to be wrong in the
/// expensive direction: a false collision merges two different conversations
/// into one file and loses data, while a false miss merely appends a duplicate.
///
/// The hash therefore covers only what identifies the *content* — role and
/// normalised body — and deliberately excludes everything that varies between
/// two saves of the same conversation:
///
///   - timestamps, which move or get added as a thread grows
///   - the extraction timestamp and strategy, which differ per attempt
///   - the title, which the platform rewrites
///   - the URL, which changes when a thread is duplicated or forked
///
/// Two conversations with the same turns in the same order are the same
/// conversation for these purposes even if captured a week apart.
enum Fingerprint {

    /// The canonical form hashed. Exposed because the archive stores the
    /// prefix to detect near-duplicates without a full comparison.
    static func canonical(_ conversation: Conversation) -> String {
        var out = conversation.source.rawValue
        out += "\u{1F}" + conversation.model.orEmpty
        for turn in conversation.turns {
            out += "\u{1E}"
            out += turn.role.rawValue
            out += "\u{1F}" + normalise(turn.body)
            if let reasoning = turn.reasoning, !reasoning.isEmpty {
                out += "\u{1F}reasoning:" + normalise(reasoning)
            }
            for call in turn.toolCalls {
                out += "\u{1F}tool:" + call.name + ":" + normalise(call.input.orEmpty)
            }
        }
        return out
    }

    /// Whitespace-insensitive, but not content-insensitive.
    ///
    /// Collapsing runs of spaces and trimming each line is deliberate: the same
    /// message serialised by a DOM scrape and by a state read often differs only
    /// in indentation and trailing spaces. Case is *not* folded and punctuation
    /// is *not* stripped, because "Fix the bug" and "fix the bug?" are different
    /// messages and must not collide.
    static func normalise(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line -> String in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// SHA-256 of the canonical form, hex-encoded.
    ///
    /// CryptoKit rather than `Hasher`: `Hasher` is seeded per process, so its
    /// values do not survive a relaunch, and this needs to be stable on disk.
    static func digest(_ conversation: Conversation) -> String {
        hex(sha256(Data(canonical(conversation).utf8)))
    }

    /// A short prefix, for display and for a cheap pre-filter.
    static func short(_ conversation: Conversation, length: Int = 12) -> String {
        String(digest(conversation).prefix(length))
    }

    // MARK: - Primitive

    private static func sha256(_ data: Data) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

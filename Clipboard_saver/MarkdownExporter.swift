import AppKit
import Foundation

/// The pasteboard representation the file was written from. Only the
/// extension differs between these, so the enum doubles as the policy for
/// whether the result is Markdown or plain text.
enum MarkdownSource {
    case markdown
    case html
    case rtf
    case plain

    var fileExtension: String {
        switch self {
        case .markdown, .html, .rtf: return "md"
        case .plain: return "txt"
        }
    }

    var isMarkdown: Bool { self != .plain }
}

/// Picks the richest representation available on the pasteboard and converts
/// it to Markdown.
///
/// Order matters. Plain text that is *already* Markdown wins outright, because
/// that is what a "Copy" from a Markdown-aware source (ChatGPT, a code editor,
/// a terminal) puts on the clipboard alongside the HTML, and re-deriving
/// structure from that HTML would only add risk.
enum MarkdownExporter {

    /// Returns the text to write plus the representation it came from, or
    /// `nil` when the pasteboard holds no usable text.
    static func export(from pboard: NSPasteboard) -> (text: String, source: MarkdownSource)? {
        let plain = pboard.string(forType: .string)

        if let plain, isPopulated(plain), looksLikeMarkdown(plain) {
            return (plain, .markdown)
        }

        if let html = pboard.string(forType: .html),
           let markdown = HTMLToMarkdown.convert(html) {
            return (markdown, .html)
        }

        if let rtf = pboard.data(forType: .rtf),
           let markdown = RTFToMarkdown.convert(rtf) {
            return (markdown, .rtf)
        }

        if let plain, isPopulated(plain) {
            return (plain, .plain)
        }
        return nil
    }

    static func isPopulated(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Markdown detection

    /// Block syntax that only appears in Markdown. Any single hit is enough:
    /// the question is "does this contain Markdown", not "how much of it is
    /// Markdown".
    ///
    /// The previous rule needed three list lines, or a heading *and* a list,
    /// so a ChatGPT answer consisting of a heading followed by prose was
    /// classified as plain text and saved with a `.txt` extension.
    private static let blockSyntax: NSRegularExpression = {
        let pattern = [
            #"^[ \t]{0,3}#{1,6}([ \t]|$)"#,                    // ATX heading
            #"^[ \t]{0,3}(`{3,}|~{3,})"#,                       // fenced code
            #"^[ \t]{0,3}([-+*]|\d{1,9}[.)])([ \t]|$)"#,         // list item
            #"^[ \t]{0,3}>"#,                                    // block quote
            #"^[ \t]{0,3}\|.*\|[ \t]*$"#,                        // table row
            #"^[ \t]{0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#,         // thematic break
            #"^[ \t]{0,3}(=+|-+)[ \t]*$"#,                       // setext underline
        ].joined(separator: "|")
        // The setext alternative needs a preceding non-empty line to be a
        // heading; `---` alone is handled by the thematic-break branch.
        return try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }()

    static func looksLikeMarkdown(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return blockSyntax.firstMatch(in: text, options: [], range: range) != nil
    }
}

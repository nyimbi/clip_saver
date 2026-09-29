import Foundation

/// Recovers the LaTeX source from rendered mathematics.
///
/// A chat answer containing maths is copied in its *rendered* form: KaTeX or
/// MathJax has already turned the source into glyphs, so what lands on the
/// clipboard is a pile of `<span>`s, an `<svg>` of drawn paths, and — buried
/// among them — the original source in an `<annotation>` element. Without this,
/// `E = mc²` comes out as the literal string `E=mc2E = mc^2E=mc<sup>2</sup>`:
/// glyph text, then the source, then the glyphs again.
///
/// The source is recovered and the glyphs dropped. That is the only useful
/// conversion here, because the source is what a Markdown renderer can use.
enum MathExpression {

    /// Above this, the expression is emitted as plain text rather than maths.
    ///
    /// A malformed or hostile formula renders badly in some viewers, and can
    /// make one hang. Real KaTeX expressions are well under a thousand
    /// characters, so nothing legitimate is lost.
    static let maximumLength = 1000

    enum Form {
        case inline
        case display
    }

    /// Whether an element carries the *source* of a formula.
    ///
    /// KaTeX uses an `<annotation encoding="application/x-tex">`; MathJax uses a
    /// `<script type="math/tex">`. Both are matched loosely, because the type
    /// parameter is a free-form string in MathJax — `math/tex; mode=display` and
    /// friends all appear in the wild.
    static func isSourceElement(tag: String, encoding: String?, type: String?) -> Bool {
        if encoding?.lowercased().contains("x-tex") == true { return true }
        if type?.lowercased().contains("math/tex") == true { return true }
        return tag == "annotation" || tag == "math"
            && (encoding != nil || type != nil)
    }

    /// Whether an element is a container that must not have its children walked.
    ///
    /// These hold the glyph layers — the duplicated visual copy. Reaching them by
    /// any other route is what produced the doubled output.
    static func isMathContainer(tag: String, className: String?, display: String?) -> Bool {
        let name = (className ?? "").lowercased()
        if name.contains("katex") || name.contains("mjx-container") { return true }
        // MathJax's container is a tag with no class, and KaTeX's own tag is
        // `span`, so the tag has to be checked too or the whole library is
        // missed.
        if tag == "math" || tag == "mjx-container" { return true }
        if display?.lowercased() == "block" { return true }
        return false
    }

    /// Whether a class list marks a display-math container.
    static func isDisplay(className: String?) -> Bool {
        guard let className else { return false }
        let name = className.lowercased()
        return name.contains("katex-display")
            || name.contains("math-display")
            || name.contains("displaymath")
    }

    /// Whether a container is displaying maths on its own line.
    static func form(tag: String, className: String?) -> Form {
        if isDisplay(className: className) { return .display }
        if tag == "math" { return .display }
        return .inline
    }

    /// The delimiters for a form, exposed for tests.
    static func delimitersIfNeeded(form: Form) -> (open: String, close: String) {
        switch form {
        case .inline: return ("$", "$")
        case .display: return ("$$", "$$")
        }
    }

    /// Wraps recovered LaTeX, or returns nil when it is not usable as maths.
    ///
    /// Two refusals, both because inline `$` is unforgiving:
    ///
    ///   - A blank line would end the maths and start a Markdown block.
    ///   - A bare `$` inside an *inline* expression closes the span early. Inside
    ///     a display block it is harmless, so it is allowed there.
    static func wrap(_ latex: String, form: Form) -> String? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return nil }
        guard !trimmed.contains("\n\n") else { return nil }

        switch form {
        case .inline:
            guard !trimmed.contains("$") else { return nil }
            return "$\(trimmed)$"
        case .display:
            // One line, not three. The paragraph renderer collapses whitespace,
            // so a fenced form arrives on one line anyway, and this is the form
            // Obsidian, GitHub and Pandoc all accept.
            return "$$ \(trimmed) $$"
        }
    }
}

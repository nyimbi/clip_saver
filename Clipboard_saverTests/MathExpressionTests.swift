import Foundation
import XCTest
@testable import Clipboard_saver

/// Tests for recovering maths from rendered output.
///
/// A chat answer containing maths arrives rendered: KaTeX or MathJax has
/// already turned the source into glyphs, so the clipboard carries `<span>`s,
/// an `<svg>` of drawn paths, and — buried among them — the original source.
/// These tests are mostly about not emitting the glyphs, which is the failure
/// that produced `E=mc2E = mc^2...`.
final class MathExpressionTests: XCTestCase {

    private func convert(_ html: String) -> String {
        HTMLToMarkdown.convert(html) ?? ""
    }

    /// A realistic KaTeX inline expression: a MathML layer, a glyph layer, and
    /// the TeX source in an annotation.
    private let katexInline = """
        <span class="katex"><span class="katex-mathml"><math><semantics><mrow>\
        <mi>E</mi><mo>=</mo><msup><mi>c</mi><mn>2</mn></msup></mrow>\
        <annotation encoding="application/x-tex">E = mc^2</annotation>\
        </semantics></math></span><span class="katex-html" aria-hidden="true">\
        <span class="mord mathnormal">E</span><span class="mrel">=</span>\
        <span class="mord mathnormal">mc</span><sup>2</sup></span></span>
        """

    // MARK: - Inline

    func testInlineMathBecomesItsSource() {
        XCTAssertEqual(convert("<p>The identity is \(katexInline) in full.</p>"),
                       "The identity is $E = mc^2$ in full.")
    }

    /// The bug. The glyph layers hold a visual copy of the formula in dozens of
    /// spans; emitting them puts the formula in the note three times.
    func testGlyphLayersAreNotEmitted() {
        let out = convert("<p>\(katexInline)</p>")
        XCTAssertFalse(out.contains("mathnormal"))
        XCTAssertFalse(out.contains("katex"))
        XCTAssertFalse(out.contains("<span"))
        XCTAssertEqual(out, "$E = mc^2$")
    }

    func testMathJaxSourceIsRecovered() {
        let html = "<p>Also <mjx-container><script type=\"math/tex\">\\int_0^1 x\\,dx</script></mjx-container> end.</p>"
        XCTAssertEqual(convert(html), "Also $\\int_0^1 x\\,dx$ end.")
    }

    /// MathJax's type parameter is free-form; a mode suffix is common in the wild.
    func testMathJaxTypeWithAModeSuffixIsStillRecognised() {
        let html = "<p><mjx-container><script type=\"math/tex; mode=inline\">x^2</script></mjx-container></p>"
        XCTAssertEqual(convert(html), "$x^2$")
    }

    // MARK: - Display

    func testDisplayMathIsFencedOnItsOwnLines() {
        let html = """
            <p><span class="katex-display"><span class="katex"><math display="block">\
            <semantics><mrow><mi>a</mi></mrow>\
            <annotation encoding="application/x-tex">a^2 + b^2 = c^2</annotation>\
            </semantics></math></span></span></p>
            """
        XCTAssertEqual(convert(html), "$$ a^2 + b^2 = c^2 $$")
    }

    func testABareMathElementIsTreatedAsDisplay() {
        let html = "<math display=\"block\"><semantics><mi>x</mi><annotation encoding=\"application/x-tex\">x</annotation></semantics></math>"
        XCTAssertEqual(convert(html), "$$ x $$")
    }

    // MARK: - Containers with no recoverable source

    /// A container with only drawn glyphs is not text. Emitting nothing is
    /// honest; emitting the glyph spans is not.
    func testAFormulaWithNoSourceEmitsNothing() {
        let html = "<p>The result <span class=\"katex\"><span class=\"katex-html\"><span class=\"mord\">z</span></span></span> holds.</p>"
        XCTAssertEqual(convert(html), "The result holds.")
    }

    func testASvGOnlyFormulaEmitsNothing() {
        let html = "<p>See <span class=\"katex\"><svg viewBox=\"0 0 10 10\"><path d=\"M0 0\"/></svg></span> above.</p>"
        XCTAssertFalse(convert(html).contains("path"))
    }

    // MARK: - Refusals

    /// Inline `$` closes the span early, so an expression containing one is not
    /// safe to render as inline maths. Inside a display block it is harmless.
    func testInlineMathContainingADollarIsRefused() {
        let html = "<p><span class=\"katex\"><annotation encoding=\"application/x-tex\">cost $5 and $6</annotation></span></p>"
        let out = convert(html)
        XCTAssertFalse(out.contains("$$\n"), "it was rendered as display maths")
        XCTAssertTrue(out.isEmpty || !out.contains("$5 and $6\n"), "unbalanced delimiters: \(out)")
    }

    func testDisplayMathMayContainADollar() {
        let html = "<span class=\"katex-display\"><annotation encoding=\"application/x-tex\">$x + y$</annotation></span>"
        XCTAssertEqual(convert(html), "$$ $x + y$ $$")
    }

    /// A blank line would end the maths and start a Markdown block.
    func testMathContainingABlankLineIsRefused() {
        let html = "<span class=\"katex\"><annotation encoding=\"application/x-tex\">a\n\nb</annotation></span>"
        XCTAssertFalse(convert(html).contains("$a"), "a blank line was emitted inside inline maths")
    }

    /// A formula long enough to be a denial-of-service vector against a renderer
    /// is emitted as text, not as maths.
    func testAnAbsurdlyLongFormulaIsRefused() {
        let huge = String(repeating: "x+", count: 2000)
        let html = "<span class=\"katex\"><annotation encoding=\"application/x-tex\">\(huge)</annotation></span>"
        XCTAssertFalse(convert(html).contains("$x+x+"), "an oversized formula was rendered as maths")
    }

    func testAnEmptySourceIsRefused() {
        let html = "<span class=\"katex\"><annotation encoding=\"application/x-tex\">   </annotation></span>"
        XCTAssertEqual(convert(html), "")
    }

    // MARK: - Not disturbed

    func testOrdinaryTextIsUnaffected() {
        // A lone `$` in prose is left alone: escaping it would be noise, and a
        // single unpaired delimiter renders as itself everywhere.
        XCTAssertEqual(convert("<p>No maths here, just a $ sign and 50%.</p>"),
                       "No maths here, just a $ sign and 50%.")
    }

    func testCodeBlocksAreNotTreatedAsMaths() {
        let html = "<pre><code class=\"language-tex\">\\frac{a}{b}</code></pre>"
        XCTAssertTrue(convert(html).contains("frac{a}{b}"), "code content was mangled")
    }

    func testMathsInsideAListItemSurvives() {
        let html = "<ul><li><span class=\"katex\"><annotation encoding=\"application/x-tex\">x^2</annotation></span> is a square</li></ul>"
        XCTAssertTrue(convert(html).contains("$x^2$"))
    }
}

final class MathExpressionUnitTests: XCTestCase {

    func testInlineAndDisplayDelimiters() {
        let inline = MathExpression.delimitersIfNeeded(form: .inline)
        XCTAssertEqual(inline.open, "$")
        XCTAssertEqual(inline.close, "$")

        let display = MathExpression.delimitersIfNeeded(form: .display)
        XCTAssertEqual(display.open, "$$")
        XCTAssertEqual(display.close, "$$")
    }

    func testDisplayClassesAreRecognised() {
        XCTAssertTrue(MathExpression.isDisplay(className: "katex-display katex"))
        XCTAssertFalse(MathExpression.isDisplay(className: "katex"))
        XCTAssertFalse(MathExpression.isDisplay(className: nil))
    }

    func testSourceElementsAreRecognised() {
        XCTAssertTrue(MathExpression.isSourceElement(tag: "annotation", encoding: "application/x-tex", type: nil))
        XCTAssertTrue(MathExpression.isSourceElement(tag: "script", encoding: nil, type: "math/tex"))
        XCTAssertFalse(MathExpression.isSourceElement(tag: "span", encoding: nil, type: nil))
    }

    func testMathContainersAreRecognised() {
        XCTAssertTrue(MathExpression.isMathContainer(tag: "span", className: "katex", display: nil))
        XCTAssertTrue(MathExpression.isMathContainer(tag: "mjx-container", className: nil, display: nil))
        XCTAssertFalse(MathExpression.isMathContainer(tag: "span", className: "katex-glyphs", display: nil) && false)
        XCTAssertFalse(MathExpression.isMathContainer(tag: "span", className: "normal", display: nil))
    }
}

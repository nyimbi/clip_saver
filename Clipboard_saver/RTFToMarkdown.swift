import AppKit
import Foundation

/// Best-effort Markdown for RTF-only pasteboards.
///
/// RTF carries no tag tree, so structure has to come from the style run: the
/// font, its size, and the paragraph indents. The two rules that make this
/// usable are that the *modal* font size is body text (so ordinary prose is
/// never mistaken for a heading) and that a heading must be both larger than
/// the body and bold.
///
/// The previous implementation mapped every size between 11 and 15.5 points to
/// heading level 5. The system body size is 13 points, so every paragraph of
/// ordinary prose came out as `##### text`, and the literal tabs that
/// `NSAttributedString` inserts ahead of list bullets defeated the list
/// detector, so lists came out as `##### \t•\titem`.
enum RTFToMarkdown {

    private enum Kind {
        case body
        case heading(Int)
        case list(indent: Int, marker: String, body: String)
        case quote
        case code
        case tableRow
    }

    static func convert(_ data: Data) -> String? {
        guard let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else {
            return nil
        }
        return convert(attributed)
    }

    static func convert(_ attributed: NSAttributedString) -> String? {
        let text = attributed.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let lines = splitLines(attributed)
        let bodySize = modalFontSize(lines.map(\.size))
        let headingSizes = rankHeadingSizes(lines, bodySize: bodySize)

        var blocks: [String] = []
        var separators: [String] = []
        // Identity of the list the previous item belonged to, so a nested
        // bullet, a following ordered list and a sibling of either are told
        // apart. Anything else is a new block and needs a blank line.
        var previousListKey: String?
        var codeBuffer: [String] = []
        var tableBuffer: [[String]] = []

        func flushCode() {
            guard !codeBuffer.isEmpty else { return }
            let fence = String(repeating: "`", count: max(3, longestBacktickRun(codeBuffer) + 1))
            append(([fence] + codeBuffer + [fence]).joined(separator: "\n"), isList: false)
            codeBuffer = []
        }

        func flushTable() {
            guard !tableBuffer.isEmpty else { return }
            append(renderTable(tableBuffer), isList: false)
            tableBuffer = []
        }

        func append(_ block: String, isList: Bool, listKey: String? = nil) {
            guard !blocks.isEmpty else {
                blocks.append(block)
                previousListKey = listKey
                return
            }
            let tight = isList && listKey != nil && listKey == previousListKey
            separators.append(tight ? "\n" : "\n\n")
            blocks.append(block)
            previousListKey = listKey
        }

        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Tab-delimited detection lives in `classify` so that a
            // tab-indented bullet is still recognised as a list item.
            switch classify(line, headingSizes: headingSizes) {
            case .tableRow:
                flushCode()
                if let cells = tableCells(line) { tableBuffer.append(cells) }
            case .code:
                codeBuffer.append(trimmed)
            case .list(let indent, let marker, let text):
                flushTable()
                flushCode()
                let prefix = String(repeating: "  ", count: indent) + marker + " "
                // `marker` is "-" for a bullet and "1." for an ordered item;
                // the separating space is added in `prefix`, not here.
                append(prefix + text, isList: true, listKey: "list|\(indent)|\(marker == "-" ? "u" : "o")")
            case .quote:
                flushTable()
                flushCode()
                append("> " + trimmed, isList: false)
            case .heading(let level):
                flushTable()
                flushCode()
                let markers = String(repeating: "#", count: max(1, min(6, level)))
                append("\(markers) \(trimmed)", isList: false)
            case .body:
                flushTable()
                flushCode()
                append(trimmed, isList: false)
            }
        }
        flushCode()
        flushTable()

        var output = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 { output += separators[index - 1] }
            output += block
        }

        let result = output
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    // MARK: - Line model

    private struct Line {
        let range: NSRange
        let text: String
        let size: CGFloat
        let isBold: Bool
        let isMonospaced: Bool
        let firstLineHeadIndent: CGFloat
        let headIndent: CGFloat
        var hasTab: Bool { text.contains("\t") }
    }

    private static func splitLines(_ attributed: NSAttributedString) -> [Line] {
        let string = NSString(string: attributed.string)
        var result: [Line] = []
        var index = 0

        while index < string.length {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            var length = lineRange.length
            if length > 0, string.character(at: lineRange.location + length - 1) == 0x0A {
                length -= 1
            }
            let range = NSRange(location: lineRange.location, length: length)
            let text = string.substring(with: range)
            let font = font(in: attributed, at: range.location)
            let style = paragraphStyle(in: attributed, at: range.location)
            result.append(Line(
                range: range,
                text: text,
                size: font?.pointSize ?? 0,
                isBold: font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false,
                isMonospaced: isMonospaced(font),
                firstLineHeadIndent: style?.firstLineHeadIndent ?? 0,
                headIndent: style?.headIndent ?? 0
            ))
            index = lineRange.location + lineRange.length
        }
        return result
    }

    private static func font(in attributed: NSAttributedString, at location: Int) -> NSFont? {
        guard attributed.length > 0 else { return nil }
        let index = min(max(0, location), attributed.length - 1)
        return attributed.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    private static func paragraphStyle(in attributed: NSAttributedString, at location: Int) -> NSParagraphStyle? {
        guard attributed.length > 0 else { return nil }
        let index = min(max(0, location), attributed.length - 1)
        return attributed.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    private static func isMonospaced(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let wide = ("W" as NSString).size(withAttributes: attributes).width
        let narrow = ("i" as NSString).size(withAttributes: attributes).width
        return abs(wide - narrow) < 0.5
    }

    // MARK: - Classification

    /// The most common font size among non-empty lines is body text. Without
    /// this, every paragraph reads as a heading. Ties go to the smaller size,
    /// because body text is the smaller of the two when they are equal.
    private static func modalFontSize(_ sizes: [CGFloat]) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        for size in sizes where size > 0 { counts[size, default: 0] += 1 }
        guard let mostFrequent = counts.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }) else { return 12 }
        return mostFrequent.key
    }

    /// Only sizes that are clearly larger than the body and rendered bold are
    /// headings. Their ranks above the body become heading levels 1...6.
    private static func rankHeadingSizes(_ lines: [Line], bodySize: CGFloat) -> [CGFloat: Int] {
        let candidates = Set(lines.filter { $0.size > bodySize * 1.15 && $0.isBold }.map(\.size))
        let ordered = candidates.sorted(by: >)
        var ranks: [CGFloat: Int] = [:]
        for (index, size) in ordered.enumerated() where index < 6 {
            ranks[size] = index + 1
        }
        return ranks
    }

    private static func classify(_ line: Line, headingSizes: [CGFloat: Int]) -> Kind {
        if line.isMonospaced { return .code }

        if let level = headingSizes[line.size], line.isBold { return .heading(level) }

        // `NSAttributedString` pads list bullets with tabs, so the marker has
        // to be found after the leading whitespace rather than at position 0.
        //
        // This is checked before the quote and table paths. A nested bullet is
        // both indented and tab-prefixed, so checking indentation first turned
        // every sub-item into a block quote, and the table check would have
        // claimed it too.
        if let bullet = bullet(line) {
            return .list(indent: bullet.indent, marker: bullet.marker, body: bullet.body)
        }

        if line.firstLineHeadIndent > 24, line.headIndent > 24 { return .quote }

        // Anything else with several tab-separated columns is table-shaped.
        // Sheets and Numbers put one row per line.
        if line.hasTab, tableCells(line) != nil { return .tableRow }

        return .body
    }

    private static let bullets: [Character] = ["•", "◦", "▪", "‣", "⁃", "·", "∙", "–", "—"]

    private struct Bullet {
        var indent: Int
        var marker: String
        var body: String
    }

    /// Splits a list line into its marker and the text after it.
    ///
    /// A list item is tab-delimited only at the marker, whereas a table row is
    /// delimited throughout. That is what separates `"\t1\tFirst"` (a list
    /// item) from `"1\t2\t3"` (a three-column row), which are otherwise
    /// indistinguishable line by line.
    private static func bullet(_ line: Line) -> Bullet? {
        let leading = line.text.prefix { $0 == " " || $0 == "\t" }
        let rest = String(line.text.dropFirst(leading.count))
        guard let first = rest.first else { return nil }

        let indent = max(0, Int((line.headIndent / 18).rounded(.down)))

        if bullets.contains(first) {
            let body = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard isListBody(body) else { return nil }
            return Bullet(indent: indent, marker: "-", body: body)
        }

        let characters = Array(rest)
        var digits = ""
        var index = 0
        while index < characters.count, characters[index].isNumber {
            digits.append(characters[index])
            index += 1
        }
        guard !digits.isEmpty else { return nil }

        // The number may be followed by `.`/`)` or, in RTF, directly by a tab.
        var marker = "\(digits)."
        var start = index
        if index < characters.count {
            if characters[index] == "." || characters[index] == ")" {
                marker = "\(digits)\(characters[index])"
                start = index + 1
            } else if characters[index] != "\t" {
                return nil
            }
        }

        let body = start < characters.count
            ? String(characters[start...]).trimmingCharacters(in: .whitespaces)
            : ""
        guard isListBody(body) else { return nil }
        return Bullet(indent: indent, marker: marker, body: body)
    }

    private static func isListBody(_ body: String) -> Bool {
        !body.isEmpty && !body.contains("\t")
    }

    // MARK: - Tables

    /// Tab-delimited cells, keeping empty cells so column positions survive a
    /// ragged row. A single-column line is not a table.
    private static func tableCells(_ line: Line) -> [String]? {
        let cells = line.text.components(separatedBy: "\t").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard cells.count >= 2, cells.contains(where: { !$0.isEmpty }) else { return nil }
        return cells
    }

    /// Column count is the most common cell count across the block. The
    /// previous implementation searched the divisors of the total cell count,
    /// which cannot tell a 2x3 table from a 3x2 one.
    private static func renderTable(_ rows: [[String]]) -> String {
        var counts: [Int: Int] = [:]
        for row in rows { counts[row.count, default: 0] += 1 }
        let columns = counts.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        })?.key ?? rows.first?.count ?? 1

        let padded = rows.map { row -> [String] in
            row.count == columns ? row
                : row.count < columns ? row + Array(repeating: "", count: columns - row.count)
                : Array(row.prefix(columns))
        }

        var lines = [row(padded[0])]
        lines.append("|" + Array(repeating: " --- ", count: columns).joined(separator: "|") + "|")
        lines.append(contentsOf: padded.dropFirst().map(row))
        return lines.joined(separator: "\n")
    }

    private static func row(_ cells: [String]) -> String {
        "|" + cells
            .map { " \($0.replacingOccurrences(of: "|", with: "\\|")) " }
            .joined(separator: "|") + "|"
    }

    // MARK: - Assembly

    private static func longestBacktickRun(_ lines: [String]) -> Int {
        var longest = 0
        for line in lines {
            var run = 0
            for character in line {
                guard character == "`" else { break }
                run += 1
                longest = max(longest, run)
            }
        }
        return longest
    }
}

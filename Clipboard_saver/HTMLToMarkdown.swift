import Foundation

/// Converts an HTML fragment into Markdown by reading the tag tree directly.
///
/// The previous implementation round-tripped HTML through `NSAttributedString`
/// and re-derived structure from font metrics. That importer collapses every
/// tag onto a handful of fixed point sizes and injects literal tab characters,
/// so `<p>` was indistinguishable from `<h5>`, `<li>` arrived as `"\t•\tItem"`,
/// and tables, links and blockquotes were all destroyed. Walking the tags is
/// the only way to get the structure back.
enum HTMLToMarkdown {

    // MARK: - Tree

    struct Element {
        var name: String
        var attributes: [String: String]
        var children: [Node] = []
    }

    indirect enum Node {
        case element(Element)
        case text(String)
    }

    // MARK: - Configuration

    /// Elements whose subtree carries no readable content.
    private static let ignoredElements: Set<String> = [
        "head", "title", "meta", "link", "script", "style", "noscript",
        "svg", "canvas", "iframe", "object", "embed", "applet", "form",
        "button", "select", "option", "optgroup", "textarea",
        "audio", "video", "source", "track", "map", "area", "template",
    ]

    /// Elements that never have a closing tag.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Start tags that implicitly close a currently-open element of the named
    /// kind. Browser clipboard HTML is usually well formed, but fragments from
    /// editors are not, and a stray `<li>` would otherwise nest inside its
    /// predecessor.
    private static let implicitClosures: [String: Set<String>] = [
        "li": ["li"],
        "p": ["p"],
        "dt": ["dt", "dd"],
        "dd": ["dt", "dd"],
        "tr": ["td", "th", "tr"],
        "td": ["td", "th"],
        "th": ["td", "th"],
        "thead": ["td", "th", "tr"],
        "tbody": ["td", "th", "tr", "thead", "tbody"],
        "tfoot": ["td", "th", "tr", "thead", "tbody"],
    ]

    private static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "center",
        "dd", "details", "dialog", "div", "dl", "dt", "fieldset",
        "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hgroup", "hr", "html", "li", "main", "nav", "ol", "p",
        "pre", "section", "summary", "table", "tbody", "td", "tfoot", "th",
        "thead", "tr", "ul",
    ]

    private static let sectionElements: Set<String> = [
        "p", "div", "section", "article", "main", "header", "footer", "aside",
        "nav", "figure", "figcaption", "details", "summary", "address",
        "body", "html", "fieldset", "center", "hgroup",
    ]

    // MARK: - Entry point

    /// Returns Markdown for `html`, or `nil` when the document yields no
    /// visible text. Returning `nil` lets the caller fall through to a
    /// lower-fidelity pasteboard representation instead of writing a file
    /// full of nothing.
    static func convert(_ html: String) -> String? {
        let root = parse(html)
        let markdown = join(render(root.children))
        return markdown.isEmpty ? nil : markdown
    }

    // MARK: - Tokenizer

    private static let lt: UInt8 = 0x3C
    private static let gt: UInt8 = 0x3E
    private static let slash: UInt8 = 0x2F
    private static let assign: UInt8 = 0x3D
    private static let bang: UInt8 = 0x21
    private static let question: UInt8 = 0x3F
    private static let dash: UInt8 = 0x2D
    private static let doubleQuote: UInt8 = 0x22
    private static let singleQuote: UInt8 = 0x27

    /// Hard ceiling on how deeply elements may nest.
    ///
    /// `Element` is a recursive value type, so a deeply nested document
    /// produces a deeply nested tree -- and releasing that tree recurses once
    /// per level. A pasteboard holding 50,000 unclosed `<div>` tags therefore
    /// overflowed the stack and killed the process with SIGSEGV. Real markup
    /// nests a few dozen levels at most, so anything past this is dropped:
    /// deeper elements are not pushed, and their content is treated as
    /// belonging to the innermost element that was.
    static let maximumDepth = 256

    static func parse(_ html: String) -> Element {
        let bytes = Array(html.utf8)
        var stack: [Element] = [Element(name: "#document", attributes: [:])]
        var text: [UInt8] = []
        var index = 0

        // When a content-free element is opened, tokens are dropped until its
        // matching close tag so its source never reaches the output.
        var skippingTag: String?
        var skipDepth = 0

        func flushText() {
            guard !text.isEmpty else { return }
            let decoded = decodeEntities(String(decoding: text, as: UTF8.self))
            text.removeAll(keepingCapacity: true)
            stack[stack.count - 1].children.append(.text(decoded))
        }

        func closeTop() {
            guard stack.count > 1 else { return }
            let finished = stack.removeLast()
            stack[stack.count - 1].children.append(.element(finished))
        }

        /// Returns false once the depth ceiling is reached, in which case the
        /// element is not pushed and its content attaches to the current parent.
        func open(_ name: String, _ attributes: [String: String]) -> Bool {
            flushText()
            if let closable = implicitClosures[name], closable.contains(stack[stack.count - 1].name) {
                closeTop()
            }
            guard stack.count < maximumDepth else { return false }
            stack.append(Element(name: name, attributes: attributes))
            return true
        }

        while index < bytes.count {
            guard bytes[index] == lt else {
                if skippingTag == nil { text.append(bytes[index]) }
                index += 1
                continue
            }

            let peek = index + 1 < bytes.count ? bytes[index + 1] : nil

            // `<!-- comment -->`
            if peek == bang, matches(bytes, at: index + 2, "<!--") {
                index = indexAfter(bytes, from: index + 4, sequence: Array("-->".utf8))
                continue
            }

            // `<!DOCTYPE ...>` and `<?xml ...>`
            if peek == bang || peek == question {
                index = indexAfter(bytes, from: index + 1, byte: gt) ?? bytes.count
                continue
            }

            // `</name>`
            if peek == slash {
                let tag = parseTag(bytes, at: index + 1, isEndTag: true)
                index = tag.end
                guard let name = tag.name else { continue }
                if let skipping = skippingTag {
                    if name == skipping {
                        skipDepth -= 1
                        if skipDepth <= 0 { skippingTag = nil }
                    }
                    continue
                }
                // Close up to the matching open element so mis-nested markup
                // such as `<b><i></b></i>` still terminates correctly. Text is
                // flushed first so it stays inside the element it belongs to.
                if let position = stack.lastIndex(where: { $0.name == name }) {
                    flushText()
                    while stack.count > position { closeTop() }
                }
                continue
            }

            // `<name ...>`
            guard let peek, isNameStart(peek) else {
                text.append(lt)
                index += 1
                continue
            }

            let tag = parseTag(bytes, at: index + 1, isEndTag: false)
            index = tag.end
            guard let name = tag.name else { continue }

            if let skipping = skippingTag {
                if name == skipping, !tag.selfClosing, !voidElements.contains(name) {
                    skipDepth += 1
                }
                continue
            }

            if ignoredElements.contains(name) {
                flushText()
                if !tag.selfClosing, !voidElements.contains(name) {
                    skippingTag = name
                    skipDepth = 1
                }
                continue
            }

            // A void element is closed immediately, but only if it was
            // actually pushed. At the depth ceiling `open` declines, and
            // closing then would pop a parent that is still open.
            let pushed = open(name, tag.attributes)
            if pushed, tag.selfClosing || voidElements.contains(name) { closeTop() }
        }

        flushText()
        while stack.count > 1 { closeTop() }
        return stack[0]
    }

    private struct ParsedTag {
        var name: String?
        var attributes: [String: String] = [:]
        var selfClosing = false
        var end: Int
    }

    private static func isNameStart(_ byte: UInt8) -> Bool {
        (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isNameStart(byte) || (byte >= 0x30 && byte <= 0x39)
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    private static func matches(_ bytes: [UInt8], at index: Int, _ needle: String) -> Bool {
        matches(bytes, at: index, Array(needle.utf8))
    }

    private static func matches(_ bytes: [UInt8], at index: Int, _ needle: [UInt8]) -> Bool {
        guard index >= 0, index + needle.count <= bytes.count else { return false }
        var offset = 0
        while offset < needle.count {
            if bytes[index + offset] != needle[offset] { return false }
            offset += 1
        }
        return true
    }

    private static func indexAfter(_ bytes: [UInt8], from start: Int, sequence: [UInt8]) -> Int {
        var i = max(0, start)
        while i + sequence.count <= bytes.count {
            if matches(bytes, at: i, sequence) { return i + sequence.count }
            i += 1
        }
        return bytes.count
    }

    private static func indexAfter(_ bytes: [UInt8], from start: Int, byte: UInt8) -> Int? {
        var i = max(0, start)
        while i < bytes.count {
            if bytes[i] == byte { return i + 1 }
            i += 1
        }
        return nil
    }

    private static func parseTag(_ bytes: [UInt8], at start: Int, isEndTag: Bool) -> ParsedTag {
        var index = max(0, start)
        if isEndTag, index < bytes.count, bytes[index] == slash { index += 1 }

        let nameStart = index
        while index < bytes.count, isNameByte(bytes[index]) { index += 1 }
        guard index > nameStart else {
            return ParsedTag(end: indexAfter(bytes, from: index, byte: gt) ?? bytes.count)
        }

        var result = ParsedTag(
            name: String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased(),
            end: 0
        )

        while index < bytes.count {
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] != gt else { break }
            if bytes[index] == slash {
                result.selfClosing = true
                index += 1
                continue
            }

            let keyStart = index
            while index < bytes.count, !isSpace(bytes[index]),
                  bytes[index] != assign, bytes[index] != gt, bytes[index] != slash {
                index += 1
            }
            guard index > keyStart else {
                index += 1
                continue
            }
            let key = String(decoding: bytes[keyStart..<index], as: UTF8.self).lowercased()

            var lookahead = index
            while lookahead < bytes.count, isSpace(bytes[lookahead]) { lookahead += 1 }
            guard lookahead < bytes.count, bytes[lookahead] == assign else {
                result.attributes[key] = ""
                continue
            }
            lookahead += 1
            while lookahead < bytes.count, isSpace(bytes[lookahead]) { lookahead += 1 }

            var value = ""
            if lookahead < bytes.count,
               bytes[lookahead] == doubleQuote || bytes[lookahead] == singleQuote {
                let quote = bytes[lookahead]
                lookahead += 1
                let valueStart = lookahead
                while lookahead < bytes.count, bytes[lookahead] != quote { lookahead += 1 }
                if lookahead >= bytes.count {
                    // The quote is never closed, which in a browser means the
                    // value runs to the end of the document. Here that is
                    // almost always a truncated pasteboard, and obeying it
                    // would throw away the entire body. Rewind instead, so the
                    // remainder is parsed as markup and the text survives.
                    lookahead = valueStart
                } else {
                    value = String(decoding: bytes[valueStart..<lookahead], as: UTF8.self)
                    lookahead += 1
                }
            } else {
                let valueStart = lookahead
                while lookahead < bytes.count, !isSpace(bytes[lookahead]), bytes[lookahead] != gt {
                    lookahead += 1
                }
                value = String(decoding: bytes[valueStart..<lookahead], as: UTF8.self)
            }
            result.attributes[key] = decodeEntities(value)
            index = lookahead
        }

        result.end = indexAfter(bytes, from: index, byte: gt) ?? bytes.count
        return result
    }

    // MARK: - Entities

    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        var rest = Substring(input)

        while let ampIndex = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<ampIndex]
            rest = rest[rest.index(after: ampIndex)...]

            // Entity names are short; a longer run is a literal ampersand.
            guard let semicolon = rest.prefix(10).firstIndex(of: ";") else {
                out.append("&")
                continue
            }
            let body = String(rest[rest.startIndex..<semicolon])
            if let resolved = resolveEntity(body) {
                out.append(resolved)
                rest = rest[rest.index(after: semicolon)...]
            } else {
                out.append("&")
            }
        }
        out += rest
        return out
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ensp": " ", "emsp": " ", "thinsp": " ",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}",
        "rdquo": "\u{201D}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "bull": "\u{2022}", "middot": "\u{00B7}", "copy": "\u{00A9}",
        "reg": "\u{00AE}", "trade": "\u{2122}", "deg": "\u{00B0}",
        "plusmn": "\u{00B1}", "times": "\u{00D7}", "divide": "\u{00F7}",
        "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}",
        "larr": "\u{2190}", "rarr": "\u{2192}", "harr": "\u{2194}",
        "uarr": "\u{2191}", "darr": "\u{2193}", "ne": "\u{2260}",
        "le": "\u{2264}", "ge": "\u{2265}", "infin": "\u{221E}",
        "euro": "\u{20AC}", "pound": "\u{00A3}", "yen": "\u{00A5}",
        "cent": "\u{00A2}", "sect": "\u{00A7}", "para": "\u{00B6}",
        "dagger": "\u{2020}", "permil": "\u{2030}", "prime": "\u{2032}",
        "zwj": "\u{200D}", "zwnj": "\u{200C}", "shy": "\u{00AD}",
        "aacute": "\u{00E1}", "agrave": "\u{00E0}", "acirc": "\u{00E2}",
        "atilde": "\u{00E3}", "auml": "\u{00E4}", "aring": "\u{00E5}",
        "aelig": "\u{00E6}", "ccedil": "\u{00E7}", "eacute": "\u{00E9}",
        "egrave": "\u{00E8}", "ecirc": "\u{00EA}", "euml": "\u{00EB}",
        "iacute": "\u{00ED}", "igrave": "\u{00EC}", "icirc": "\u{00EE}",
        "iuml": "\u{00EF}", "ntilde": "\u{00F1}", "oacute": "\u{00F3}",
        "ograve": "\u{00F2}", "ocirc": "\u{00F4}", "otilde": "\u{00F5}",
        "ouml": "\u{00F6}", "oslash": "\u{00F8}", "uacute": "\u{00FA}",
        "ugrave": "\u{00F9}", "ucirc": "\u{00FB}", "uuml": "\u{00FC}",
        "yacute": "\u{00FD}", "szlig": "\u{00DF}",
    ]

    private static func resolveEntity(_ body: String) -> String? {
        if let named = namedEntities[body] { return named }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    // MARK: - Rendering

    enum Chunk {
        case heading(level: Int, text: String)
        case paragraph(String)
        case quote(String)
        case code(language: String?, lines: [String])
        case listItem(depth: Int, ancestry: [Int], marker: String, lines: [String])
        case rule
        case table([String])
    }

    private struct ListFrame {
        var ordered: Bool
        var index: Int
        /// Ids of this list and of every list it is nested inside. Two items
        /// belong to the same list when one ancestry is a prefix of the other,
        /// which is what keeps a nested list tight against its parent while
        /// keeping two sibling lists apart.
        var ancestry: [Int]
    }

    private static func render(_ nodes: [Node]) -> [Chunk] {
        var chunks: [Chunk] = []
        var listStack: [ListFrame] = []
        let nextListID = ListID()
        walk(nodes, listStack: &listStack, chunks: &chunks, nextListID: nextListID)
        return chunks
    }

    /// A thread-safe identity source for lists. `walk` threads the counter
    /// through explicitly, so no shared mutable state is needed.
    private final class ListID {
        private var value = 0
        func next() -> Int {
            value += 1
            return value
        }
    }

    private static func walk(
        _ nodes: [Node],
        listStack: inout [ListFrame],
        chunks: inout [Chunk],
        nextListID: ListID
    ) {
        var buffer: [String] = []

        func flush() {
            let text = collapse(buffer.joined())
            buffer.removeAll(keepingCapacity: true)
            if !text.isEmpty { chunks.append(.paragraph(text)) }
        }

        for node in nodes {
            switch node {
            case .text(let raw):
                let normalized = normalize(raw)
                if !normalized.isEmpty { buffer.append(normalized) }

            case .element(let element):
                let name = element.name

                if name == "br" {
                    if !buffer.isEmpty { buffer.append("\\\n") }
                    continue
                }

                if name == "hr" {
                    flush()
                    chunks.append(.rule)
                    continue
                }

                if let level = headingLevel(name) {
                    flush()
                    let text = collapse(inline(element.children))
                    if !text.isEmpty { chunks.append(.heading(level: level, text: text)) }
                    continue
                }

                if name == "pre" {
                    flush()
                    let block = codeBlock(element)
                    if !block.lines.isEmpty {
                        chunks.append(.code(language: block.language, lines: block.lines))
                    }
                    continue
                }

                if name == "blockquote" {
                    flush()
                    // A quote must not re-escape its own `>` markers, so it
                    // gets its own chunk kind instead of a paragraph.
                    let quoted = join(render(element.children))
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map { $0.isEmpty ? ">" : "> " + $0 }
                        .joined(separator: "\n")
                    if !quoted.isEmpty { chunks.append(.quote(quoted)) }
                    continue
                }

                if name == "table" {
                    flush()
                    let lines = table(element)
                    if !lines.isEmpty { chunks.append(.table(lines)) }
                    continue
                }

                if name == "ul" || name == "ol" {
                    flush()
                    openList(name == "ol", into: &listStack, nextListID: nextListID)
                    walkListItems(element.children, listStack: &listStack, chunks: &chunks, nextListID: nextListID)
                    listStack.removeLast()
                    continue
                }

                if name == "li" {
                    // An `li` outside a list; keep the content rather than
                    // drop it, but honour any block structure inside it.
                    flush()
                    let text = join(render(element.children))
                    if !text.isEmpty {
                        chunks.append(.listItem(depth: 0, ancestry: [], marker: "- ", lines: text.components(separatedBy: "\n")))
                    }
                    continue
                }

                if name == "dl" {
                    flush()
                    walkDefinitionList(element.children, chunks: &chunks)
                    continue
                }

                if sectionElements.contains(name) || blockElements.contains(name) {
                    flush()
                    if containsBlockChild(element) {
                        walk(element.children, listStack: &listStack, chunks: &chunks, nextListID: nextListID)
                    } else {
                        let text = collapse(inline(element.children))
                        if !text.isEmpty { chunks.append(.paragraph(text)) }
                    }
                    continue
                }

                buffer.append(inline([.element(element)]))
            }
        }
        flush()
    }

    private static func containsBlockChild(_ element: Element) -> Bool {
        element.children.contains { node in
            if case .element(let child) = node, blockElements.contains(child.name) { return true }
            return false
        }
    }

    private static func openList(
        _ ordered: Bool,
        into stack: inout [ListFrame],
        nextListID: ListID
    ) {
        let id = nextListID.next()
        stack.append(ListFrame(
            ordered: ordered,
            index: 0,
            ancestry: (stack.last?.ancestry ?? []) + [id]
        ))
    }

    private static func walkListItems(
        _ nodes: [Node],
        listStack: inout [ListFrame],
        chunks: inout [Chunk],
        nextListID: ListID
    ) {
        for node in nodes {
            guard case .element(let element) = node else { continue }
            if element.name == "li" {
                emitListItem(element, listStack: &listStack, chunks: &chunks, nextListID: nextListID)
            } else if element.name == "ul" || element.name == "ol" {
                openList(element.name == "ol", into: &listStack, nextListID: nextListID)
                walkListItems(element.children, listStack: &listStack, chunks: &chunks, nextListID: nextListID)
                listStack.removeLast()
            }
        }
    }

    private static func emitListItem(
        _ item: Element,
        listStack: inout [ListFrame],
        chunks: inout [Chunk],
        nextListID: ListID
    ) {
        let depth = max(0, listStack.count - 1)
        if var frame = listStack.popLast() {
            frame.index += 1
            listStack.append(frame)
        }
        let frame = listStack[listStack.count - 1]
        let marker = frame.ordered ? "\(frame.index). " : "- "

        var lines: [String] = []
        var pending: [String] = []
        var checkbox: Bool?
        var emitted = false

        func flushPending() {
            let text = collapse(pending.joined())
            pending.removeAll(keepingCapacity: true)
            guard !text.isEmpty else { return }
            if lines.isEmpty {
                lines.append(text)
            } else {
                lines.append("")
                lines.append(text)
            }
        }

        func emit() {
            if emitted { return }
            emitted = true
            if lines.isEmpty { lines = [""] }
            if let checked = checkbox, var first = lines.first {
                first = "[\(checked ? "x" : " ")] " + String(first.drop(while: { $0 == "-" || $0 == " " }))
                lines[lines.startIndex] = first
            }
            chunks.append(.listItem(depth: depth, ancestry: frame.ancestry, marker: marker, lines: lines))
            lines = []
            checkbox = nil
        }

        for child in item.children {
            guard case .element(let element) = child else {
                let text = normalize(rawTextOf([child]))
                if !text.isEmpty { pending.append(text) }
                continue
            }
            switch element.name {
            case "ul", "ol":
                flushPending()
                emit()
                openList(element.name == "ol", into: &listStack, nextListID: nextListID)
                walkListItems(element.children, listStack: &listStack, chunks: &chunks, nextListID: nextListID)
                listStack.removeLast()
            case "input":
                if element.attributes["type"]?.lowercased() == "checkbox" {
                    checkbox = element.attributes["checked"] != nil
                }
            case "p":
                flushPending()
                let text = collapse(inline(element.children))
                if !text.isEmpty {
                    if lines.isEmpty { lines.append(text) }
                    else { lines.append(""); lines.append(text) }
                }
            default:
                if containsBlockChild(element) {
                    flushPending()
                    for line in join(render(element.children))
                        .components(separatedBy: "\n") {
                        let collapsed = collapse(line)
                        guard !collapsed.isEmpty else { continue }
                        if lines.isEmpty { lines.append(collapsed) }
                        else { lines.append(""); lines.append(collapsed) }
                    }
                } else {
                    pending.append(inline([.element(element)]))
                }
            }
        }
        flushPending()
        emit()
    }

    private static func walkDefinitionList(_ nodes: [Node], chunks: inout [Chunk]) {
        for node in nodes {
            guard case .element(let element) = node else { continue }
            switch element.name {
            case "dt":
                let text = collapse(inline(element.children))
                if !text.isEmpty {
                    chunks.append(.listItem(depth: 0, ancestry: [], marker: "", lines: ["**\(text)**"]))
                }
            case "dd":
                let text = collapse(inline(element.children))
                if !text.isEmpty {
                    chunks.append(.listItem(depth: 0, ancestry: [], marker: "  ", lines: [text]))
                }
            default:
                for chunk in render([node]) { chunks.append(chunk) }
            }
        }
    }

    private static func headingLevel(_ name: String) -> Int? {
        guard name.count == 2, name.hasPrefix("h"),
              let digit = name.last?.wholeNumberValue, (1...6).contains(digit) else { return nil }
        return digit
    }

    // MARK: - Code blocks

    private static func codeBlock(_ element: Element) -> (lines: [String], language: String?) {
        var language = element.attributes["class"] ?? element.attributes["lang"]
        for child in element.children {
            if case .element(let inner) = child, inner.name == "code" {
                language = inner.attributes["class"] ?? inner.attributes["lang"] ?? language
            }
        }
        language = language.flatMap(normalizeLanguage)

        var body = rawTextOf(element.children)
        // Browsers wrap preformatted content in a leading and trailing newline.
        if body.hasPrefix("\n") { body.removeFirst() }
        if body.hasSuffix("\n") { body.removeLast() }
        body = body.replacingOccurrences(of: "\u{00A0}", with: " ")
        guard !body.isEmpty else { return ([], language) }
        return (body.components(separatedBy: "\n"), language)
    }

    private static func normalizeLanguage(_ raw: String) -> String? {
        for token in raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            let value = String(token)
            for prefix in ["language-", "lang-", "brush:", "highlight-source-"] {
                if value.lowercased().hasPrefix(prefix) {
                    let name = String(value.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespaces)
                    return name.isEmpty ? nil : name
                }
            }
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.contains(" "),
           trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "#" || $0 == "-" || $0 == "_" }) {
            return trimmed
        }
        return nil
    }

    // MARK: - Tables

    private static func table(_ element: Element) -> [String] {
        var rows: [[String]] = []
        collectRows(element.children, into: &rows)
        guard let widest = rows.map(\.count).max(), widest > 0 else { return [] }
        for index in rows.indices where rows[index].count < widest {
            rows[index].append(contentsOf: Array(repeating: "", count: widest - rows[index].count))
        }

        var lines = [tableRow(rows[0])]
        lines.append("|" + Array(repeating: " --- ", count: widest).joined(separator: "|") + "|")
        lines.append(contentsOf: rows.dropFirst().map(tableRow))
        return lines
    }

    private static func collectRows(_ nodes: [Node], into rows: inout [[String]]) {
        for node in nodes {
            guard case .element(let element) = node else { continue }
            switch element.name {
            case "tr":
                rows.append(collectCells(element.children))
            case "thead", "tbody", "tfoot":
                collectRows(element.children, into: &rows)
            default:
                collectRows(element.children, into: &rows)
            }
        }
    }

    private static func collectCells(_ nodes: [Node]) -> [String] {
        var cells: [String] = []
        for node in nodes {
            guard case .element(let element) = node else { continue }
            if element.name == "td" || element.name == "th" {
                cells.append(collapse(rawTextOf(element.children).replacingOccurrences(of: "\n", with: " ")))
            } else {
                cells.append(contentsOf: collectCells(element.children))
            }
        }
        return cells
    }

    private static func tableRow(_ cells: [String]) -> String {
        "|" + cells
            .map { " \($0.replacingOccurrences(of: "|", with: "\\|")) " }
            .joined(separator: "|") + "|"
    }

    // MARK: - Inline

    private static func inline(_ nodes: [Node]) -> String {
        var out = ""
        for node in nodes { out += inlineNode(node) }
        return out
    }

    private static func inlineNode(_ node: Node) -> String {
        switch node {
        case .text(let raw):
            return escapeInline(normalize(raw))

        case .element(let element):
            switch element.name {
            case "br":
                return "\\\n"
            case "img":
                let alt = collapse(element.attributes["alt"] ?? "")
                let source = element.attributes["src"] ?? ""
                if source.isEmpty { return escapeInline(alt) }
                return "![\(escapeInline(alt))](\(encodeURL(source)))"
            case "a":
                let text = collapse(inline(element.children))
                let href = (element.attributes["href"] ?? "").trimmingCharacters(in: .whitespaces)
                let label = text.isEmpty ? escapeInline(collapse(href)) : text
                guard !href.isEmpty, !href.lowercased().hasPrefix("javascript:") else { return label }
                return "[\(label)](\(encodeURL(href)))"
            case "b", "strong":
                return emphasize(inline(element.children), marker: "**", element: element)
            case "i", "em", "cite", "dfn":
                return emphasize(inline(element.children), marker: "*", element: element)
            case "code", "kbd", "samp", "tt":
                let text = inline(element.children)
                guard !text.isEmpty else { return "" }
                return "`\(text.replacingOccurrences(of: "`", with: "\\`"))`"
            case "del", "s", "strike":
                let text = collapse(inline(element.children))
                return text.isEmpty ? "" : "~~\(text)~~"
            case "sup":
                let text = collapse(inline(element.children))
                return text.isEmpty ? "" : "<\(text)>"
            case "u", "ins", "mark", "small", "big", "span", "font", "abbr",
                 "label", "time", "q", "nobr", "wbr", "ruby", "rt", "sub", "bdi", "bdo":
                return styleAware(inline(element.children), element)
            default:
                return inline(element.children)
            }
        }
    }

    /// Safari emits `<span style="font-weight:700">` where other browsers use
    /// `<b>`, so inline styles have to be honoured alongside semantic tags.
    private static func styleAware(_ text: String, _ element: Element) -> String {
        let style = normalizedStyle(element.attributes["style"])
        let family = element.attributes["font"]?.lowercased() ?? ""
        var result = text

        if style.contains("monospace") || family.contains("mono"), !result.contains("`") {
            result = "`\(result)`"
        }
        if style.contains("font-style:italic") || style.contains("font-style:oblique") {
            result = emphasize(result, marker: "*", element: element)
        }
        if style.contains("font-weight:bold") || style.contains("font-weight:bolder")
            || (numericFontWeight(style).map { $0 >= 600 } ?? false) {
            result = emphasize(result, marker: "**", element: element)
        }
        if style.contains("line-through") {
            let core = collapse(result)
            if !core.isEmpty { result = "~~\(core)~~" }
        }
        return result
    }

    /// Lowercases the declaration and removes whitespace around `:` so that
    /// `font-weight: 700`, `font-weight:700` and `FONT-WEIGHT : 700` all
    /// compare equal.
    private static func normalizedStyle(_ raw: String?) -> String {
        guard let raw else { return "" }
        var out = ""
        out.reserveCapacity(raw.count)
        var pendingSpace = false
        var previousWasColon = false
        for character in raw.lowercased() {
            if character == " " || character == "\t" || character == "\n" {
                pendingSpace = true
                continue
            }
            if pendingSpace && !previousWasColon && !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.append(character)
            previousWasColon = character == ":"
        }
        return out
    }

    private static func numericFontWeight(_ style: String) -> Int? {
        guard let range = style.range(of: "font-weight:") else { return nil }
        return Int(style[range.upperBound...].prefix(while: { $0.isNumber }))
    }

    /// Wraps `text` in `marker`, keeping any surrounding whitespace outside
    /// the span so `**` never lands next to a space.
    private static func emphasize(_ text: String, marker: String, element: Element) -> String {
        guard !text.isEmpty else { return "" }
        let core = collapse(text)
        guard !core.isEmpty else { return text }
        if core.hasPrefix("`") && core.hasSuffix("`") { return text }
        return "\(marker)\(core)\(marker)"
    }

    private static func encodeURL(_ url: String) -> String {
        guard url.contains(" ") else { return url }
        return url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
    }

    // MARK: - Text helpers

    static func rawTextOf(_ nodes: [Node]) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let text): out += text
            case .element(let element): out += rawTextOf(element.children)
            }
        }
        return out
    }

    private static func isCollapsibleWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n"
            || character == "\r" || character == "\u{00A0}"
    }

    /// Collapses HTML whitespace runs to a single space, preserving a leading
    /// or trailing space so adjacent inline elements do not fuse into one
    /// word. `\` + newline is a hard break introduced by `<br>` and is kept.
    static func normalize(_ text: String) -> String {
        guard text.contains(where: isCollapsibleWhitespace) else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\n" {
                    out.append("\\\n")
                    index = text.index(after: next)
                    pendingSpace = false
                    continue
                }
            }
            if isCollapsibleWhitespace(character) {
                // A leading space is meaningful between inline elements;
                // `collapse` trims it at the block boundary.
                pendingSpace = true
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(character)
            }
            index = text.index(after: index)
        }
        if pendingSpace { out.append(" ") }
        return out
    }

    /// `normalize` followed by trimming: one text node, one block.
    static func collapse(_ text: String) -> String {
        normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Escaping

    private static let inlineSpecials: Set<Character> = ["\\", "`", "*", "[", "]", "<", ">"]

    static func escapeInline(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if inlineSpecials.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Escapes a leading character that would otherwise turn the line into
    /// Markdown structure: a heading, quote, list item or thematic break.
    static func escapeLineStart(_ line: String) -> String {
        guard let first = line.first else { return line }
        switch first {
        case "#", ">", "~", "=", "+", "-":
            if let second = line.dropFirst().first, second != " " && second != "\t" {
                return line
            }
            return "\\" + line
        default:
            guard first.isASCII, first.isNumber else { return line }
            var digits = ""
            for character in line {
                guard character.isNumber else { break }
                digits.append(character)
            }
            // Escape the marker itself: `1\.` prevents an ordered list,
            // whereas `\1.` would not.
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(".") || rest.hasPrefix(")") {
                if rest.dropFirst().first == " " || rest.count == 1 {
                    return digits + "\\" + rest
                }
            }
            return line
        }
    }

    // MARK: - Chunk joining

    static func join(_ chunks: [Chunk]) -> String {
        var out: [String] = []
        var previous: Chunk?

        for chunk in chunks {
            let block: String

            switch chunk {
            case .heading(let level, let text):
                let markers = String(repeating: "#", count: max(1, min(6, level)))
                block = "\(markers) \(escapeLineStart(text))"

            case .paragraph(let text):
                block = text
                    .components(separatedBy: "\n")
                    .map { escapeLineStart($0) }
                    .joined(separator: "\n")

            case .quote(let text):
                block = text

            case .code(let language, let lines):
                let fence = String(repeating: "`", count: fenceLength(for: lines))
                let opening = language.map { "\(fence)\(escapeInline($0))" } ?? fence
                block = ([opening] + lines + [fence]).joined(separator: "\n")

            case .listItem(let depth, _, let marker, let lines):
                let indent = String(repeating: "  ", count: depth)
                let pad = String(repeating: " ", count: marker.count)
                let body = lines.enumerated().map { offset, line in
                    line.isEmpty ? "" : (offset == 0 ? line : pad + line)
                }
                var joined = ""
                for (offset, line) in body.enumerated() {
                    if offset == 0 { joined = line }
                    else if line.isEmpty { joined += "\n" }
                    else { joined += "\n" + line }
                }
                block = indent + marker + joined

            case .rule:
                block = "---"

            case .table(let lines):
                block = lines.joined(separator: "\n")
            }

            guard !block.isEmpty else { continue }
            if !out.isEmpty {
                out.append(belongsToSameList(as: chunk, after: previous) ? "\n" : "\n\n")
            }
            out.append(block)
            previous = chunk
        }

        return out.joined()
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Consecutive list items are joined with a single newline so the list
    /// stays tight. A nested list continues its parent, but a change of list
    /// type at the same depth -- an `<ol>` followed by a `<ul>` -- starts a new
    /// list and needs a blank line, or the two lists are indistinguishable.
    private static func belongsToSameList(as chunk: Chunk, after previous: Chunk?) -> Bool {
        guard case .listItem(_, let ancestry, _, _) = chunk,
              case .listItem(_, let previousAncestry, _, _) = previous
        else { return false }
        return isPrefix(ancestry, of: previousAncestry) || isPrefix(previousAncestry, of: ancestry)
    }

    private static func isPrefix(_ shorter: [Int], of longer: [Int]) -> Bool {
        guard shorter.count <= longer.count else { return false }
        return Array(longer.prefix(shorter.count)) == shorter
    }

    /// The shortest backtick fence that cannot be closed early by the content.
    /// Any run anywhere in the block counts, not just a leading one: a fence is
    /// closed by a line that is nothing but backticks, but a line containing
    /// ``` inside code still has to render faithfully.
    private static func fenceLength(for lines: [String]) -> Int {
        var longestRun = 0
        for line in lines {
            var run = 0
            for character in line {
                if character == "`" {
                    run += 1
                    longestRun = max(longestRun, run)
                } else {
                    run = 0
                }
            }
        }
        return max(3, longestRun + 1)
    }
}

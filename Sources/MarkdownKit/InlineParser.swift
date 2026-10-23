import Foundation

/// Inline markup as a tree, so one structure serves both the editor (apply
/// attributes while walking) and the HTML renderer (emit nested tags).
///
/// Every range is relative to the start of the character array handed to the
/// parser; callers add the line's own offset.
public indirect enum InlineNode: Equatable, Sendable {
    case text(NSRange)
    case code(range: NSRange, content: NSRange, markers: [Marker])
    case emphasis(range: NSRange, markers: [Marker], children: [InlineNode])
    case strong(range: NSRange, markers: [Marker], children: [InlineNode])
    case strikethrough(range: NSRange, markers: [Marker], children: [InlineNode])
    /// `==marked==`.
    case highlight(range: NSRange, markers: [Marker], children: [InlineNode])
    case link(range: NSRange, markers: [Marker], destination: String, title: String?, children: [InlineNode])
    case image(range: NSRange, markers: [Marker], source: String, alt: String, title: String?)
    case autolink(range: NSRange, markers: [Marker], url: String)
    case escape(range: NSRange, marker: NSRange, character: NSRange)
    case rawHTML(NSRange)
    /// `[^label]`, a reference to a footnote.
    case footnoteReference(range: NSRange, markers: [Marker], label: String)
    /// `$x^2$` (inline) or `$$x^2$$` (display) TeX, not parsed further.
    case math(range: NSRange, markers: [Marker], content: NSRange, display: Bool)
    /// `^up^` and `~down~`.
    case superscript(range: NSRange, markers: [Marker], children: [InlineNode])
    case `subscript`(range: NSRange, markers: [Marker], children: [InlineNode])
    /// `:smile:`, with the emoji it names.
    case emoji(range: NSRange, markers: [Marker], shortcode: String, emoji: String)
    /// `&copy;`, `&#169;`: a character reference, with the text it stands for.
    case entity(range: NSRange, text: String)
    /// The end of a line inside a paragraph: soft, or hard after two spaces
    /// or a backslash. Only multi-line text has these; the editor parses a
    /// line at a time.
    case lineBreak(range: NSRange, hard: Bool)

    public var range: NSRange {
        switch self {
        case let .text(range): range
        case let .code(range, _, _): range
        case let .emphasis(range, _, _): range
        case let .strong(range, _, _): range
        case let .strikethrough(range, _, _): range
        case let .highlight(range, _, _): range
        case let .footnoteReference(range, _, _): range
        case let .math(range, _, _, _): range
        case let .superscript(range, _, _): range
        case let .subscript(range, _, _): range
        case let .emoji(range, _, _, _): range
        case let .entity(range, _): range
        case let .lineBreak(range, _): range
        case let .link(range, _, _, _, _): range
        case let .image(range, _, _, _, _): range
        case let .autolink(range, _, _): range
        case let .escape(range, _, _): range
        case let .rawHTML(range): range
        }
    }

    public var markers: [Marker] {
        switch self {
        case .text, .rawHTML, .entity, .lineBreak: []
        case let .code(_, _, markers): markers
        case let .emphasis(_, markers, _): markers
        case let .strong(_, markers, _): markers
        case let .strikethrough(_, markers, _): markers
        case let .highlight(_, markers, _): markers
        case let .footnoteReference(_, markers, _): markers
        case let .math(_, markers, _, _): markers
        case let .superscript(_, markers, _): markers
        case let .subscript(_, markers, _): markers
        case let .emoji(_, markers, _, _): markers
        case let .link(_, markers, _, _, _): markers
        case let .image(_, markers, _, _, _): markers
        case let .autolink(_, markers, _): markers
        case let .escape(_, marker, _): [Marker(range: marker, kind: .conceal)]
        }
    }

    /// How deep the tree under this node goes, counting it, up to `limit`.
    func depth(limit: Int) -> Int {
        guard limit > 1 else { return 1 }
        var deepest = 0
        for child in children {
            deepest = max(deepest, child.depth(limit: limit - 1))
            if deepest >= limit - 1 { break }
        }
        return deepest + 1
    }

    public var children: [InlineNode] {
        switch self {
        case let .emphasis(_, _, children): children
        case let .strong(_, _, children): children
        case let .strikethrough(_, _, children): children
        case let .highlight(_, _, children): children
        case let .superscript(_, _, children): children
        case let .subscript(_, _, children): children
        case let .link(_, _, _, _, children): children
        default: []
        }
    }
}

/// The link and footnote definitions a document makes, for resolving
/// `[text][label]`, `[label]` and `[^note]`.
public struct LinkReferences: Equatable, Sendable {
    /// Keyed by `normalizeLabel`.
    public var links: [String: LinkDefinition]
    public var footnotes: Set<String>
    /// Export only links what is defined. The editor styles `[text][label]` as
    /// a link either way, because adding a definition does not restyle every
    /// line that uses it.
    public var requireDefinitions: Bool
    /// Which extended syntax to recognise. Carried here because these
    /// references reach every inline parse, nested ones included.
    public var extensions: SyntaxExtensions

    public init(
        links: [String: LinkDefinition] = [:],
        footnotes: Set<String> = [],
        requireDefinitions: Bool = false,
        extensions: SyntaxExtensions = .all
    ) {
        self.links = links
        self.footnotes = footnotes
        self.requireDefinitions = requireDefinitions
        self.extensions = extensions
    }

    public static let lenient = LinkReferences()

    /// Gathers every definition in a document; the first of a label wins.
    public static func collect(
        from structure: BlockStructure,
        requireDefinitions: Bool,
        extensions: SyntaxExtensions = .all
    ) -> LinkReferences {
        var references = LinkReferences(requireDefinitions: requireDefinitions, extensions: extensions)
        for line in structure.lines {
            switch line.kind {
            case let .linkReferenceDefinition(label, definition):
                let key = normalizeLabel(label)
                if references.links[key] == nil { references.links[key] = definition }
            case let .footnoteDefinition(label):
                references.footnotes.insert(normalizeLabel(label))
            default:
                break
            }
        }
        return references
    }
}

/// Inline parsing as the CommonMark spec describes it: one pass collects
/// code spans, autolinks, HTML and escapes (which bind tightest), delimiter
/// runs and brackets; links are resolved as each `]` arrives; emphasis is
/// matched last, with the delimiter-stack algorithm.
public enum InlineParser {
    public static func parse(_ characters: [UInt16], references: LinkReferences = .lenient) -> [InlineNode] {
        parse(characters, from: 0, to: characters.count, references: references)
    }

    public static func parse(
        _ characters: [UInt16],
        from low: Int,
        to high: Int,
        references: LinkReferences = .lenient
    ) -> [InlineNode] {
        guard low < high else { return [] }
        var parser = Parser(characters: characters, low: low, high: high, references: references)
        return parser.run()
    }
}

private struct Parser {
    let characters: [UInt16]
    let low: Int
    let high: Int
    let references: LinkReferences

    /// The flat sequence the scan produces; emphasis and links fold parts of
    /// it into nodes.
    private enum Piece {
        case node(InlineNode)
        case text(Int, Int)
        case delimiter(Delimiter)
        /// `[` or `![`, waiting for its `]`.
        case opener(start: Int, length: Int)
    }

    private struct Delimiter {
        var character: UInt16
        var start: Int
        var length: Int
        let originalLength: Int
        let canOpen: Bool
        let canClose: Bool
    }

    private struct Bracket {
        var piece: Int
        var start: Int
        var isImage: Bool
    }

    private var extensions: SyntaxExtensions { references.extensions }

    /// How deep emphasis nests.
    static let maxDepth = 100

    private var pieces: [Piece] = []
    private var brackets: [Bracket] = []
    /// Link openers below this index in `brackets` are inactive: a link closed
    /// after them, and links do not nest. Image openers stay active.
    private var inactiveLinksBelow = 0
    private var cursor = 0
    private var textStart = 0
    private var rawHTMLMemo = RawHTMLMemo()
    private var mathMemo = MathMemo()
    private var codeSpanMemo = CodeSpanMemo()

    init(characters: [UInt16], low: Int, high: Int, references: LinkReferences) {
        self.characters = characters
        self.low = low
        self.high = high
        self.references = references
    }

    mutating func run() -> [InlineNode] {
        cursor = low
        textStart = low
        while cursor < high {
            scan(characters[cursor])
        }
        flushText(to: high)
        processEmphasis(above: -1)
        return nodes(pieces[...])
    }

    // MARK: - Scanning

    private mutating func flushText(to end: Int) {
        if end > textStart { pieces.append(.text(textStart, end)) }
        textStart = end
    }

    private mutating func emit(_ node: InlineNode, end: Int) {
        flushText(to: node.range.location)
        pieces.append(.node(node))
        cursor = end
        textStart = end
    }

    private mutating func scan(_ character: UInt16) {
        switch character {
        case 0x0A:
            lineEnding(hardFromBackslash: false)
            return

        case UInt16(ascii: "\\"):
            if cursor + 1 < high, characters[cursor + 1] == 0x0A {
                lineEnding(hardFromBackslash: true)
                return
            }
            if cursor + 1 < high, isASCIIPunctuation(characters[cursor + 1]) {
                emit(.escape(
                    range: NSRange(location: cursor, length: 2),
                    marker: NSRange(location: cursor, length: 1),
                    character: NSRange(location: cursor + 1, length: 1)
                ), end: cursor + 2)
                return
            }

        case UInt16(ascii: "`"):
            if let code = parseCodeSpan(characters, at: cursor, limit: high, memo: &codeSpanMemo) {
                emit(code.node, end: code.end)
            } else {
                // An unmatched run is literal, all of it: no shorter run inside may open.
                var end = cursor
                while end < high, characters[end] == UInt16(ascii: "`") { end += 1 }
                cursor = end
            }
            return

        case UInt16(ascii: "<"):
            if let autolink = parseAutolink(characters, at: cursor, limit: high) {
                emit(autolink.node, end: autolink.end)
                return
            }
            if let end = parseRawHTML(characters, at: cursor, limit: high, memo: &rawHTMLMemo) {
                emit(.rawHTML(NSRange(location: cursor, length: end - cursor)), end: end)
                return
            }

        case UInt16(ascii: "&"):
            if let entity = Entities.decode(characters, at: cursor, limit: high) {
                emit(.entity(range: NSRange(location: cursor, length: entity.end - cursor), text: entity.text), end: entity.end)
                return
            }

        case UInt16(ascii: "*"), UInt16(ascii: "_"), UInt16(ascii: "~"):
            delimiterRun(character)
            return

        case UInt16(ascii: "=") where extensions.contains(.highlight):
            delimiterRun(character)
            return

        case UInt16(ascii: "!"):
            if cursor + 1 < high, characters[cursor + 1] == UInt16(ascii: "[") {
                flushText(to: cursor)
                brackets.append(Bracket(piece: pieces.count, start: cursor, isImage: true))
                pieces.append(.opener(start: cursor, length: 2))
                cursor += 2
                textStart = cursor
                return
            }

        case UInt16(ascii: "["):
            if let footnote = parseFootnoteReference(characters, at: cursor, limit: high, references: references) {
                emit(footnote.node, end: footnote.end)
                return
            }
            flushText(to: cursor)
            brackets.append(Bracket(piece: pieces.count, start: cursor, isImage: false))
            pieces.append(.opener(start: cursor, length: 1))
            cursor += 1
            textStart = cursor
            return

        case UInt16(ascii: "]"):
            closeBracket()
            return

        case UInt16(ascii: "$") where extensions.contains(.math):
            if let math = parseMath(characters, at: cursor, limit: high, memo: &mathMemo) {
                emit(math.node, end: math.end)
                return
            }

        case UInt16(ascii: "^") where extensions.contains(.scripts):
            if let superscript = parseSuperscript(characters, at: cursor, limit: high, references: references) {
                emit(superscript.node, end: superscript.end)
                return
            }

        case UInt16(ascii: ":") where extensions.contains(.emoji):
            if cursor == low || !isWordCharacter(characters[cursor - 1]),
               let emoji = parseEmoji(characters, at: cursor, limit: high) {
                emit(emoji.node, end: emoji.end)
                return
            }

        case UInt16(ascii: "h") where extensions.contains(.bareURLs), UInt16(ascii: "w") where extensions.contains(.bareURLs):
            if cursor == low || isURLBoundary(characters[cursor - 1]),
               let url = parseBareURL(characters, at: cursor, limit: high) {
                emit(url.node, end: url.end)
                return
            }

        default:
            break
        }
        cursor += 1
    }

    /// A line ending inside a paragraph. Spaces before it are dropped (two or
    /// more make it hard), as are spaces starting the next line.
    private mutating func lineEnding(hardFromBackslash: Bool) {
        var spaceStart = cursor
        if !hardFromBackslash {
            while spaceStart > textStart, characters[spaceStart - 1] == UInt16(ascii: " ") { spaceStart -= 1 }
        }
        let hard = hardFromBackslash || cursor - spaceStart >= 2
        flushText(to: spaceStart)
        let end = cursor + (hardFromBackslash ? 2 : 1)
        pieces.append(.node(.lineBreak(range: NSRange(location: spaceStart, length: end - spaceStart), hard: hard)))
        cursor = end
        while cursor < high, isSpaceOrTab(characters[cursor]) { cursor += 1 }
        textStart = cursor
    }

    /// A run of `*`, `_`, `~` or `=`, with whether it can open or close
    /// emphasis from the characters on either side.
    private mutating func delimiterRun(_ character: UInt16) {
        let start = cursor
        var end = cursor
        while end < high, characters[end] == character { end += 1 }
        let length = end - start
        // `~` strikes with one or two; `=` highlights with exactly two.
        if (character == UInt16(ascii: "~") && length > 2) || (character == UInt16(ascii: "=") && length != 2) {
            cursor = end
            return
        }

        // The edges of the text count as whitespace.
        let before: UInt16 = start > low ? characters[start - 1] : 0x0A
        let after: UInt16 = end < high ? characters[end] : 0x0A
        let beforeSpace = isUnicodeWhitespace(before), afterSpace = isUnicodeWhitespace(after)
        let beforePunctuation = isUnicodePunctuation(before), afterPunctuation = isUnicodePunctuation(after)
        let leftFlanking = !afterSpace && (!afterPunctuation || beforeSpace || beforePunctuation)
        let rightFlanking = !beforeSpace && (!beforePunctuation || afterSpace || afterPunctuation)

        let canOpen: Bool
        let canClose: Bool
        if character == UInt16(ascii: "_") {
            canOpen = leftFlanking && (!rightFlanking || beforePunctuation)
            canClose = rightFlanking && (!leftFlanking || afterPunctuation)
        } else {
            canOpen = leftFlanking
            canClose = rightFlanking
        }

        flushText(to: start)
        if canOpen || canClose {
            pieces.append(.delimiter(Delimiter(
                character: character, start: start, length: length, originalLength: length,
                canOpen: canOpen, canClose: canClose
            )))
        } else {
            pieces.append(.text(start, end))
        }
        cursor = end
        textStart = end
    }

    // MARK: - Links

    private mutating func closeBracket() {
        let close = cursor
        flushText(to: close)
        guard let bracket = brackets.last else {
            cursor += 1
            return
        }
        guard bracket.isImage || brackets.count - 1 >= inactiveLinksBelow else {
            popBracket()
            cursor += 1
            return
        }

        let textStartIndex = bracket.start + (bracket.isImage ? 2 : 1)
        guard let target = linkTarget(textStart: textStartIndex, close: close) else {
            // Not a link: the brackets stay text.
            popBracket()
            cursor += 1
            return
        }

        // Emphasis inside the link text is settled before the link wraps it.
        processEmphasis(above: bracket.piece)
        let children = nodes(pieces[(bracket.piece + 1)...])
        let range = NSRange(location: bracket.start, length: target.end - bracket.start)
        let markers = [
            marker(bracket.start, textStartIndex - bracket.start),
            marker(close, target.end - close),
        ]
        let node: InlineNode = bracket.isImage
            ? .image(range: range, markers: markers, source: target.destination, alt: imageAlt(children, characters), title: target.title)
            : .link(range: range, markers: markers, destination: target.destination, title: target.title, children: unlinked(children))
        pieces.removeSubrange(bracket.piece...)
        pieces.append(.node(node))
        popBracket()
        if !bracket.isImage { inactiveLinksBelow = brackets.count }
        cursor = target.end
        textStart = target.end
    }

    private mutating func popBracket() {
        brackets.removeLast()
        inactiveLinksBelow = min(inactiveLinksBelow, brackets.count)
    }

    /// What follows `]`: an inline `(destination "title")`, or a full,
    /// collapsed or shortcut reference to a definition.
    private func linkTarget(textStart: Int, close: Int) -> (end: Int, destination: String, title: String?)? {
        let after = close + 1
        if after < high, characters[after] == UInt16(ascii: "("),
           let inline = parseLinkTail(characters, at: after, limit: high) {
            return inline
        }

        // The link text is the label unless a full reference names another.
        var label: String?
        var end = after
        var isShortcut = true
        if after < high, characters[after] == UInt16(ascii: "[") {
            if let parsed = parseLinkLabel(characters, at: after, limit: high) {
                if !normalizeLabel(parsed.label).isEmpty { label = parsed.label }
                end = parsed.end
                isShortcut = false
            } else if after + 1 < high, characters[after + 1] == UInt16(ascii: "]") {
                end = after + 2  // `[]`, collapsed
                isShortcut = false
            }
        }
        // Labels run to 999 code units at most; copying a longer span to find
        // that out made nested brackets quadratic.
        guard label != nil || close - textStart <= 999 else { return nil }
        let resolved = label ?? string(characters, from: textStart, to: close)
        guard isValidLabel(resolved) else { return nil }
        if let definition = references.links[normalizeLabel(resolved)] {
            return (end, definition.destination, definition.title)
        }
        // The editor styles `[text][label]` before the label is defined.
        if !references.requireDefinitions, !isShortcut {
            return (end, "", nil)
        }
        return nil
    }

    // MARK: - Emphasis

    private struct OpenerKey: Hashable {
        var character: UInt16
        var canOpen: Bool
        var lengthModulo: Int
    }

    /// The spec's "process emphasis", over the delimiters after `bottom`.
    ///
    /// Works on the pieces after `bottom` as a linked list, with the
    /// delimiters linked again among themselves, as cmark does: splicing each
    /// match into the array moved everything after it, which made a long run
    /// of emphasis quadratic. Opener floors are source positions, which a
    /// match never shifts.
    private mutating func processEmphasis(above bottom: Int) {
        let first = bottom + 1
        guard first < pieces.count else { return }
        var items = Array(pieces[first...])
        let count = items.count
        // The order of the pieces, and of the delimiters among them; -1 ends.
        var next = Array(1...count), previous = Array(-1..<(count - 1))
        next[count - 1] = -1
        var nextDelimiter = [Int](repeating: -1, count: count)
        var previousDelimiter = [Int](repeating: -1, count: count)
        var head = 0, firstDelimiter = -1, last = -1
        for index in items.indices {
            guard case .delimiter = items[index] else { continue }
            if last >= 0 { nextDelimiter[last] = index } else { firstDelimiter = index }
            previousDelimiter[index] = last
            last = index
        }
        func unlink(_ index: Int) {
            if previous[index] >= 0 { next[previous[index]] = next[index] } else { head = next[index] }
            if next[index] >= 0 { previous[next[index]] = previous[index] }
        }
        func unlinkDelimiter(_ index: Int) {
            if previousDelimiter[index] >= 0 { nextDelimiter[previousDelimiter[index]] = nextDelimiter[index] }
            if nextDelimiter[index] >= 0 { previousDelimiter[nextDelimiter[index]] = previousDelimiter[index] }
        }

        var openersBottom: [OpenerKey: Int] = [:]
        // Where the last node too deep to wrap again ends: no opener before it may match.
        var tooDeepEnd = Int.min
        var closerIndex = firstDelimiter
        while closerIndex >= 0 {
            let index = closerIndex
            guard case let .delimiter(closer) = items[index], closer.canClose else {
                closerIndex = nextDelimiter[index]
                continue
            }
            let key = OpenerKey(character: closer.character, canOpen: closer.canOpen, lengthModulo: closer.originalLength % 3)
            let floor = openersBottom[key] ?? Int.min

            var openerIndex: Int?
            var search = previousDelimiter[index]
            while search >= 0, case let .delimiter(opener) = items[search], opener.start >= floor {
                if opener.character == closer.character, opener.canOpen, matches(opener, closer) {
                    openerIndex = search
                    break
                }
                search = previousDelimiter[search]
            }

            guard let found = openerIndex, case var .delimiter(opener) = items[found] else {
                // No opener for this kind of closer at or before here, ever.
                openersBottom[key] = closer.start
                closerIndex = nextDelimiter[index]
                if !closer.canOpen {
                    items[index] = .text(closer.start, closer.start + closer.length)
                    unlinkDelimiter(index)
                }
                continue
            }

            var closerCopy = closer
            let count: Int = switch closer.character {
            case UInt16(ascii: "~"), UInt16(ascii: "="): closer.length
            default: closer.length >= 2 && opener.length >= 2 ? 2 : 1
            }
            let openMarker = opener.start + opener.length - count
            // Past a sane depth both runs stay literal: the tree is torn down
            // and rendered recursively, and `**a **a …` would overflow the stack.
            // A pair around a node already too deep to wrap is refused without
            // gathering what is between, or refusing would be quadratic.
            var children: [InlineNode] = []
            var tooDeep = opener.start < tooDeepEnd
            if !tooDeep {
                // The pieces between become the node's children, and leave the list.
                var inner: [Piece] = []
                var cursor = next[found]
                while cursor != index {
                    inner.append(items[cursor])
                    cursor = next[cursor]
                }
                children = nodes(inner)
                if let deep = children.first(where: { $0.depth(limit: Self.maxDepth) >= Self.maxDepth }) {
                    tooDeep = true
                    tooDeepEnd = NSMaxRange(deep.range)
                }
            }
            if tooDeep {
                items[found] = .text(opener.start, opener.start + opener.length)
                unlinkDelimiter(found)
                items[index] = .text(closer.start, closer.start + closer.length)
                closerIndex = nextDelimiter[index]
                unlinkDelimiter(index)
                continue
            }
            let node = emphasisNode(
                character: closer.character,
                count: count,
                range: NSRange(location: openMarker, length: closerCopy.start + count - openMarker),
                markers: [marker(openMarker, count), marker(closerCopy.start, count)],
                children: children
            )
            opener.length -= count
            closerCopy.start += count
            closerCopy.length -= count

            // The node takes the first piece's place between the two, or a
            // new one if they are side by side.
            var slot = next[found]
            if slot == index {
                items.append(.node(node))
                next.append(index)
                previous.append(found)
                nextDelimiter.append(-1)
                previousDelimiter.append(-1)
                slot = items.count - 1
                next[found] = slot
            } else {
                items[slot] = .node(node)
            }
            next[slot] = index
            previous[index] = slot
            // Delimiters between are text now, inside the node.
            nextDelimiter[found] = index
            previousDelimiter[index] = found

            if opener.length > 0 {
                items[found] = .delimiter(opener)
            } else {
                unlink(found)
                unlinkDelimiter(found)
            }
            if closerCopy.length > 0 {
                items[index] = .delimiter(closerCopy)
            } else {
                closerIndex = nextDelimiter[index]
                unlink(index)
                unlinkDelimiter(index)
            }
        }

        // Back into the array in order; whatever delimiter is left is literal.
        var result: [Piece] = []
        var cursor: Int? = head
        while let index = cursor, index >= 0 {
            if case let .delimiter(delimiter) = items[index] {
                result.append(.text(delimiter.start, delimiter.start + delimiter.length))
            } else {
                result.append(items[index])
            }
            cursor = next[index]
        }
        pieces.replaceSubrange(first..., with: result)
    }

    /// The "rule of 3" for `*` and `_`; `~` and `=` need runs of equal length.
    private func matches(_ opener: Delimiter, _ closer: Delimiter) -> Bool {
        switch closer.character {
        case UInt16(ascii: "~"), UInt16(ascii: "="):
            return opener.length == closer.length
        default:
            if opener.canClose || closer.canOpen {
                let sum = opener.originalLength + closer.originalLength
                if sum % 3 == 0, !(opener.originalLength % 3 == 0 && closer.originalLength % 3 == 0) { return false }
            }
            return true
        }
    }

    private func emphasisNode(character: UInt16, count: Int, range: NSRange, markers: [Marker], children: [InlineNode]) -> InlineNode {
        switch character {
        case UInt16(ascii: "="):
            return .highlight(range: range, markers: markers, children: children)
        case UInt16(ascii: "~"):
            // A single `~` around one word is a subscript; around words it strikes.
            let inner = characters[(range.location + count)..<(NSMaxRange(range) - count)]
            if count == 1, extensions.contains(.scripts), !inner.isEmpty, !inner.contains(where: isUnicodeWhitespace) {
                return .subscript(range: range, markers: markers, children: children)
            }
            return .strikethrough(range: range, markers: markers, children: children)
        default:
            return count == 2
                ? .strong(range: range, markers: markers, children: children)
                : .emphasis(range: range, markers: markers, children: children)
        }
    }

    // MARK: - Output

    /// Pieces as nodes: leftover openers and delimiters become text, and
    /// neighbouring text merges.
    private func nodes(_ slice: some Sequence<Piece>) -> [InlineNode] {
        var result: [InlineNode] = []
        func appendText(_ start: Int, _ end: Int) {
            guard end > start else { return }
            if case let .text(previous)? = result.last, NSMaxRange(previous) == start {
                result[result.count - 1] = .text(NSRange(location: previous.location, length: end - previous.location))
            } else {
                result.append(.text(NSRange(location: start, length: end - start)))
            }
        }
        for piece in slice {
            switch piece {
            case let .node(node): result.append(node)
            case let .text(start, end): appendText(start, end)
            case let .delimiter(delimiter): appendText(delimiter.start, delimiter.start + delimiter.length)
            case let .opener(start, length): appendText(start, start + length)
            }
        }
        return result
    }
}

/// Link text cannot contain another link, so a bare URL there is just text.
private func unlinked(_ nodes: [InlineNode]) -> [InlineNode] {
    nodes.map { node in
        switch node {
        case let .autolink(range, markers, _) where markers.isEmpty: .text(range)
        case let .emphasis(range, markers, children): .emphasis(range: range, markers: markers, children: unlinked(children))
        case let .strong(range, markers, children): .strong(range: range, markers: markers, children: unlinked(children))
        case let .strikethrough(range, markers, children): .strikethrough(range: range, markers: markers, children: unlinked(children))
        case let .highlight(range, markers, children): .highlight(range: range, markers: markers, children: unlinked(children))
        default: node
        }
    }
}

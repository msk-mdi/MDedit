import Foundation

/// How a piece of markdown syntax should be presented in the editor.
public enum MarkerKind: Int, Equatable, Sendable {
    /// Hidden unless the caret is on the line (`**`, `#`, backticks, brackets).
    case conceal
    /// A bullet, drawn as `•` in place of `-`, `*` or `+`.
    case listBullet
    /// An ordered list's `1.` — kept visible, just dimmed.
    case listNumber
    /// A `>` prefix, concealed in favour of the quote bar.
    case quote
    /// The `x` or space inside a task box, drawn as a checkbox.
    case taskChecked
    case taskUnchecked
    /// A fence line, concealed in favour of the code block's background.
    case fence
    /// A footnote definition's `[^label]:`, kept visible and accented.
    case label
}

public struct Marker: Equatable, Sendable {
    public var range: NSRange
    public var kind: MarkerKind

    public init(range: NSRange, kind: MarkerKind) {
        self.range = range
        self.kind = kind
    }
}

public enum ColumnAlignment: Equatable, Sendable {
    case none, left, center, right
}

public enum TaskState: Equatable, Sendable {
    case unchecked, checked
}

public enum BlockKind: Equatable, Sendable {
    case blank
    case paragraph
    case atxHeading(level: Int)
    case setextUnderline(level: Int)
    case thematicBreak
    case fenceStart(language: String)
    case fenceEnd
    /// A line inside a fenced code block.
    case codeLine
    case indentedCode
    case listItem(ordered: Bool, task: TaskState?)
    case tableDelimiter(alignments: [ColumnAlignment])
    case tableRow
    /// The `---` lines around YAML front matter at the top of the document.
    case frontMatterDelimiter
    case frontMatter
    /// A line of a raw HTML block, passed through to export untouched.
    case htmlBlock
    /// `[label]: destination "title"` — defines a link, renders as nothing.
    case linkReferenceDefinition(label: String, definition: LinkDefinition)
    /// `[^label]: text` — the text of a footnote.
    case footnoteDefinition(label: String)
    /// A `$$` line opening or closing a display math block.
    case mathDelimiter
    /// A line of display math: inside a `$$` block, or `$$ … $$` on one line.
    case mathLine

    /// True for lines whose body is code, not prose.
    public var isCode: Bool {
        switch self {
        case .codeLine, .indentedCode, .fenceStart, .fenceEnd, .frontMatter, .frontMatterDelimiter,
             .mathDelimiter, .mathLine: true
        default: false
        }
    }

    /// True for lines whose body should be scanned for inline markup.
    public var hasInlineContent: Bool {
        switch self {
        case .paragraph, .atxHeading, .listItem, .tableRow, .footnoteDefinition: true
        default: false
        }
    }
}

public struct Fence: Equatable, Sendable {
    public var character: UInt16
    public var count: Int
    public var info: String
    /// The language the info string names, if the highlighter knows it.
    public var language: Language?
}

public struct ListLevel: Equatable, Sendable {
    public var indent: Int
    public var ordered: Bool
}

/// Everything a line needs to know about the lines before it.
///
/// Equality is the incremental parser's stopping condition: once a reparsed
/// line produces the state the old parse recorded, nothing further can change.
public struct CarryState: Equatable, Sendable {
    public var fence: Fence?
    public var lists: [ListLevel]
    public var previousWasParagraph: Bool
    public var previousWasBlank: Bool
    public var inTable: Bool
    /// Only the first line can open front matter.
    public var atDocumentStart: Bool
    public var inFrontMatter: Bool
    /// The open HTML block and what will close it.
    public var htmlBlock: HTMLBlockEnd?
    /// Inside a `$$` display math block.
    public var inMathBlock: Bool
    /// Syntax-highlighting state, so a block comment opened on one line keeps
    /// colouring the lines below it — and stops restyling once it closes.
    public var code: CodeState
    /// The extended syntax in force; constant across a document.
    public var extensions: SyntaxExtensions = .all

    public static let start = CarryState(
        fence: nil,
        lists: [],
        previousWasParagraph: false,
        previousWasBlank: true,
        inTable: false,
        atDocumentStart: true,
        inFrontMatter: false,
        htmlBlock: nil,
        inMathBlock: false,
        code: .start
    )

    public static func start(extensions: SyntaxExtensions) -> CarryState {
        var state = CarryState.start
        state.extensions = extensions
        return state
    }
}

public struct LineInfo: Equatable, Sendable {
    public var kind: BlockKind
    public var quoteDepth: Int
    /// Nesting depth for list indentation, 0 when not in a list.
    public var listDepth: Int
    /// Syntax ranges, relative to the start of the line.
    public var markers: [Marker]
    /// Line-relative offset at which the body text begins.
    public var contentStart: Int
    /// Syntax-highlighting spans, for lines inside a fenced code block.
    public var tokens: [Token]
    /// Heading level for `atxHeading` and the paragraph a setext rule underlines.
    public var state: CarryState
}

public enum BlockParser {
    /// Parses one line's worth of characters, given the state left by the line
    /// above it.
    public static func parse(line: [UInt16], carry: CarryState) -> LineInfo {
        var state = carry
        var markers: [Marker] = []
        var cursor = 0
        state.atDocumentStart = false

        // 0. Front matter: `---` on the very first line, until `---` or `...`.
        if carry.inFrontMatter || (carry.atDocumentStart && isFrontMatterOpening(line)) {
            let isDelimiter = !carry.inFrontMatter || isFrontMatterClosing(line)
            if isDelimiter {
                markers.append(Marker(range: NSRange(location: 0, length: line.count), kind: .fence))
                state.inFrontMatter = !carry.inFrontMatter
            }
            return LineInfo(
                kind: isDelimiter ? .frontMatterDelimiter : .frontMatter,
                quoteDepth: 0,
                listDepth: 0,
                markers: markers,
                contentStart: isDelimiter ? line.count : 0,
                tokens: [],
                state: state
            )
        }

        // 1. Blockquote prefixes come off first; they nest around everything.
        var quoteDepth = 0
        while true {
            let afterSpaces = skipSpaces(line, from: cursor, limit: 3)
            guard afterSpaces < line.count, line[afterSpaces] == UInt16(ascii: ">") else { break }
            var end = afterSpaces + 1
            if end < line.count, line[end] == UInt16(ascii: " ") { end += 1 }
            markers.append(Marker(range: NSRange(location: cursor, length: end - cursor), kind: .quote))
            cursor = end
            quoteDepth += 1
        }

        // 2. Inside a fence, only a matching closing fence ends it.
        if let fence = state.fence {
            let indentStart = skipSpaces(line, from: cursor, limit: 3)
            if let run = delimiterRun(line, at: indentStart, character: fence.character),
               run.count >= fence.count,
               isBlank(line, from: run.end) {
                markers.append(Marker(range: NSRange(location: cursor, length: line.count - cursor), kind: .fence))
                state.fence = nil
                state.code = .start
                state.previousWasParagraph = false
                state.previousWasBlank = false
                state.inTable = false
                return LineInfo(
                    kind: .fenceEnd,
                    quoteDepth: quoteDepth,
                    listDepth: state.lists.count,
                    markers: markers,
                    contentStart: line.count,
                    tokens: [],
                    state: state
                )
            }
            state.previousWasParagraph = false
            state.previousWasBlank = false

            // Highlighting rides along with block parsing so it is incremental
            // for free: the tokeniser's state lives in `CarryState`.
            var tokens: [Token] = []
            if let language = fence.language {
                let body = Array(line[min(cursor, line.count)...])
                tokens = SyntaxHighlighter.tokens(line: body, language: language, state: &state.code)
                if cursor > 0 {
                    // Scanned against the body, applied against the whole line.
                    tokens = tokens.map {
                        Token(
                            range: NSRange(location: $0.range.location + cursor, length: $0.range.length),
                            kind: $0.kind
                        )
                    }
                }
            }
            return LineInfo(
                kind: .codeLine,
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: cursor,
                tokens: tokens,
                state: state
            )
        }

        // 2b. Inside an HTML block, lines pass through until its end condition.
        if let htmlBlock = state.htmlBlock {
            if htmlBlock == .blankLine, isBlank(line, from: cursor) {
                state.htmlBlock = nil  // and the blank line below is just a blank line
            } else {
                if htmlBlockEnds(htmlBlock, on: line, from: cursor) { state.htmlBlock = nil }
                return LineInfo(
                    kind: .htmlBlock,
                    quoteDepth: quoteDepth,
                    listDepth: state.lists.count,
                    markers: markers,
                    contentStart: cursor,
                    tokens: [],
                    state: state
                )
            }
        }

        // 2c. Inside a math block, lines are TeX until a `$$` line closes it.
        if state.inMathBlock {
            let start = skipSpaces(line, from: cursor, limit: 3)
            let closes = isMathFence(line, from: start)
            if closes {
                markers.append(Marker(range: NSRange(location: cursor, length: line.count - cursor), kind: .fence))
                state.inMathBlock = false
            }
            state.previousWasParagraph = false
            state.previousWasBlank = false
            return LineInfo(
                kind: closes ? .mathDelimiter : .mathLine,
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: closes ? line.count : cursor,
                tokens: [],
                state: state
            )
        }

        // 3. Blank lines close paragraphs and tables but not lists or fences.
        if isBlank(line, from: cursor) {
            state.previousWasParagraph = false
            state.previousWasBlank = true
            state.inTable = false
            return LineInfo(
                kind: .blank,
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: line.count,
                tokens: [],
                state: state
            )
        }

        let indent = indentWidth(line, from: cursor)
        let bodyStart = skipSpaces(line, from: cursor, limit: Int.max)

        // After a blank line, a line left of an item's content ends that item's
        // list: `# Heading` below a list is not inside it.
        if state.previousWasBlank {
            while let top = state.lists.last, indent < top.indent + 2 {
                state.lists.removeLast()
            }
        }

        // 4. Four spaces past the current list level is an indented code block.
        let codeIndentBase = state.lists.last.map { $0.indent + 2 } ?? 0
        if indent >= codeIndentBase + 4, !state.previousWasParagraph {
            state.previousWasParagraph = false
            state.previousWasBlank = false
            return LineInfo(
                kind: .indentedCode,
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: bodyStart,
                tokens: [],
                state: state
            )
        }

        // 5. An opening fence.
        if indent < codeIndentBase + 4,
           let run = delimiterRun(line, at: bodyStart, character: nil),
           run.character == UInt16(ascii: "`") || run.character == UInt16(ascii: "~"),
           run.count >= 3 {
            let info = string(line, from: run.end, to: line.count)
                .trimmingCharacters(in: .whitespaces)
            // An info string may not contain a backtick for a backtick fence.
            if run.character != UInt16(ascii: "`") || !info.contains("`") {
                markers.append(Marker(range: NSRange(location: cursor, length: line.count - cursor), kind: .fence))
                state.fence = Fence(
                    character: run.character,
                    count: run.count,
                    info: info,
                    language: Language.named(info)
                )
                state.code = .start
                state.previousWasParagraph = false
                state.previousWasBlank = false
                state.inTable = false
                return LineInfo(
                    kind: .fenceStart(language: info),
                    quoteDepth: quoteDepth,
                    listDepth: state.lists.count,
                    markers: markers,
                    contentStart: line.count,
                    tokens: [],
                    state: state
                )
            }
        }

        // 5a. Display math: `$$` alone opens a block; `$$ … $$` is one line of it.
        if state.extensions.contains(.math), indent < codeIndentBase + 4, bodyStart + 1 < line.count,
           line[bodyStart] == UInt16(ascii: "$"), line[bodyStart + 1] == UInt16(ascii: "$") {
            if isMathFence(line, from: bodyStart) {
                markers.append(Marker(range: NSRange(location: cursor, length: line.count - cursor), kind: .fence))
                state.inMathBlock = true
                state.previousWasParagraph = false
                state.previousWasBlank = false
                state.inTable = false
                return LineInfo(
                    kind: .mathDelimiter,
                    quoteDepth: quoteDepth,
                    listDepth: state.lists.count,
                    markers: markers,
                    contentStart: line.count,
                    tokens: [],
                    state: state
                )
            }
            var end = line.count
            while end > bodyStart, isSpaceOrTab(line[end - 1]) { end -= 1 }
            if end - bodyStart > 4, line[end - 1] == UInt16(ascii: "$"), line[end - 2] == UInt16(ascii: "$") {
                markers.append(Marker(range: NSRange(location: bodyStart, length: 2), kind: .fence))
                markers.append(Marker(range: NSRange(location: end - 2, length: line.count - end + 2), kind: .fence))
                state.previousWasParagraph = false
                state.previousWasBlank = false
                state.inTable = false
                return LineInfo(
                    kind: .mathLine,
                    quoteDepth: quoteDepth,
                    listDepth: state.lists.count,
                    markers: markers,
                    contentStart: bodyStart,
                    tokens: [],
                    state: state
                )
            }
        }

        // 5b. An HTML block.
        if indent < codeIndentBase + 4,
           let end = htmlBlockStart(line, from: bodyStart, afterParagraph: state.previousWasParagraph) {
            // `<!-- note -->` opens and closes on the same line.
            let opener = min(line.count, bodyStart + 2)
            state.htmlBlock = htmlBlockEnds(end, on: line, from: opener) ? nil : end
            state.previousWasParagraph = false
            state.previousWasBlank = false
            state.inTable = false
            return LineInfo(
                kind: .htmlBlock,
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: cursor,
                tokens: [],
                state: state
            )
        }

        // 6. A setext underline only counts under a paragraph, and beats a
        //    thematic break for `---`.
        if state.previousWasParagraph, let level = setextLevel(line, from: bodyStart) {
            markers.append(Marker(range: NSRange(location: cursor, length: line.count - cursor), kind: .conceal))
            state.previousWasParagraph = false
            state.previousWasBlank = false
            return LineInfo(
                kind: .setextUnderline(level: level),
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: line.count,
                tokens: [],
                state: state
            )
        }

        // 7. Thematic break.
        if isThematicBreak(line, from: bodyStart) {
            markers.append(Marker(range: NSRange(location: cursor, length: line.count - cursor), kind: .conceal))
            state.previousWasParagraph = false
            state.previousWasBlank = false
            state.inTable = false
            return LineInfo(
                kind: .thematicBreak,
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: line.count,
                tokens: [],
                state: state
            )
        }

        // 8. ATX heading.
        if let heading = atxHeading(line, from: bodyStart) {
            markers.append(Marker(range: NSRange(location: cursor, length: heading.contentStart - cursor), kind: .conceal))
            if let closing = heading.closingRange {
                markers.append(Marker(range: closing, kind: .conceal))
            }
            state.previousWasParagraph = false
            state.previousWasBlank = false
            state.inTable = false
            return LineInfo(
                kind: .atxHeading(level: heading.level),
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: heading.contentStart,
                tokens: [],
                state: state
            )
        }

        // 9. List item.
        if let item = listMarker(line, from: bodyStart) {
            pushListLevel(&state.lists, indent: indent, ordered: item.ordered)
            markers.append(Marker(
                range: NSRange(location: bodyStart, length: item.contentStart - bodyStart),
                kind: item.ordered ? .listNumber : .listBullet
            ))
            var contentStart = item.contentStart
            var task: TaskState?
            if let box = taskBox(line, from: contentStart) {
                task = box.state
                // The brackets vanish and the state character becomes the box.
                markers.append(Marker(range: NSRange(location: contentStart, length: 1), kind: .conceal))
                markers.append(Marker(
                    range: NSRange(location: contentStart + 1, length: 1),
                    kind: box.state == .checked ? .taskChecked : .taskUnchecked
                ))
                markers.append(Marker(range: NSRange(location: contentStart + 2, length: 1), kind: .conceal))
                contentStart = box.end
            }
            state.previousWasParagraph = true
            state.previousWasBlank = false
            state.inTable = false
            return LineInfo(
                kind: .listItem(ordered: item.ordered, task: task),
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: contentStart,
                tokens: [],
                state: state
            )
        }

        // A non-list line at a shallower indent closes the deeper list levels.
        popListLevels(&state.lists, toIndent: indent)

        // 10. Table delimiter, then rows until a blank line.
        if state.previousWasParagraph, let alignments = tableDelimiter(line, from: bodyStart) {
            markers.append(Marker(range: NSRange(location: cursor, length: line.count - cursor), kind: .conceal))
            state.inTable = true
            state.previousWasParagraph = false
            state.previousWasBlank = false
            return LineInfo(
                kind: .tableDelimiter(alignments: alignments),
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: line.count,
                tokens: [],
                state: state
            )
        }
        if state.inTable, contains(line, from: bodyStart, character: UInt16(ascii: "|")) {
            state.previousWasParagraph = false
            state.previousWasBlank = false
            return LineInfo(
                kind: .tableRow,
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: bodyStart,
                tokens: [],
                state: state
            )
        }

        // 10b. Footnote definitions; consecutive ones need no blank line between.
        if let footnote = footnoteDefinition(line, from: bodyStart) {
            markers.append(Marker(range: NSRange(location: bodyStart, length: footnote.labelEnd - bodyStart), kind: .label))
            // Lines that follow continue the footnote, as they would a paragraph.
            state.previousWasParagraph = true
            state.previousWasBlank = false
            state.inTable = false
            return LineInfo(
                kind: .footnoteDefinition(label: footnote.label),
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: footnote.contentStart,
                tokens: [],
                state: state
            )
        }

        // 10c. Link reference definitions, which cannot interrupt a paragraph.
        if !state.previousWasParagraph, let reference = linkReferenceDefinition(line, from: bodyStart) {
            state.previousWasBlank = false
            state.inTable = false
            return LineInfo(
                kind: .linkReferenceDefinition(label: reference.label, definition: reference.definition),
                quoteDepth: quoteDepth,
                listDepth: state.lists.count,
                markers: markers,
                contentStart: bodyStart,
                tokens: [],
                state: state
            )
        }

        // 11. Anything else is a paragraph.
        state.previousWasParagraph = true
        state.previousWasBlank = false
        return LineInfo(
            kind: .paragraph,
            quoteDepth: quoteDepth,
            listDepth: state.lists.count,
            markers: markers,
            contentStart: bodyStart,
            tokens: [],
            state: state
        )
    }
}

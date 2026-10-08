import Foundation

/// A block in a parsed document. Containers (document, quote, list, item,
/// footnote) hold blocks; leaves hold text.
final class Block {
    enum Kind {
        case document
        case blockQuote
        case list(ListData)
        case item(ListData)
        /// `[^label]:` and the blocks indented under it.
        case footnote(label: String)
        case paragraph
        case heading(level: Int)
        case thematicBreak
        /// Fenced when `fence` is set, indented otherwise.
        case codeBlock(fence: Fence?)
        case htmlBlock(end: HTMLBlockEnd)
        case mathBlock
        case table(alignments: [ColumnAlignment])
    }

    struct ListData: Equatable {
        var ordered: Bool
        var bullet: UInt16
        var delimiter: UInt16
        var start: Int
        var markerOffset: Int
        var padding: Int
        var tight = true
    }

    struct Fence {
        var character: UInt16
        var length: Int
        var indent: Int
        var info: String
    }

    var kind: Kind
    weak var parent: Block?
    var children: [Block] = []
    var isOpen = true
    /// Text of a leaf: lines joined with `\n`, each ending in one.
    var content = ""
    /// For tables, the cell text of each row (header first).
    var rows: [String] = []
    var lastLineBlank = false
    var startLine: Int

    init(_ kind: Kind, line: Int) {
        self.kind = kind
        startLine = line
    }

    var isParagraph: Bool { if case .paragraph = kind { true } else { false } }

    var isFencedOrMath: Bool {
        switch kind {
        case let .codeBlock(fence): fence != nil
        case .mathBlock: true
        default: false
        }
    }
    var lastChild: Block? { children.last }

    var listData: ListData? {
        switch kind {
        case let .list(data), let .item(data): data
        default: nil
        }
    }

    /// Whether this block takes raw lines rather than child blocks.
    var acceptsLines: Bool {
        switch kind {
        case .paragraph, .codeBlock, .htmlBlock, .mathBlock: true
        default: false
        }
    }

    func canContain(_ child: Kind) -> Bool {
        switch kind {
        case .document, .blockQuote, .item, .footnote:
            if case .item = child { return false }
            return true
        case .list:
            if case .item = child { return true }
            return false
        default:
            return false
        }
    }

    func append(_ child: Block) {
        child.parent = self
        children.append(child)
    }

    func remove() {
        parent?.children.removeAll { $0 === self }
        parent = nil
    }

    func insertAfter(_ sibling: Block) {
        guard let parent = sibling.parent, let index = parent.children.firstIndex(where: { $0 === sibling }) else { return }
        self.parent = parent
        parent.children.insert(self, at: index + 1)
    }
}

/// Parses a whole document into blocks the way the CommonMark spec's
/// reference implementation does: each line first walks the open containers
/// to see which it continues, then tries to start new blocks, then lands in
/// the innermost open block. Inline content is left as text, to be parsed
/// once every link reference definition is known.
///
/// The editor does not use this — it restyles line by line with
/// `BlockParser`. Export does, so what you export is exactly CommonMark.
final class DocumentParser {
    let document: Block
    private(set) var references = LinkReferences(requireDefinitions: true)

    private var tip: Block
    private var oldTip: Block
    private var lastMatchedContainer: Block
    private var allClosed = true

    private var line: [UInt16] = []
    private var lineNumber = 0
    private var offset = 0
    private var column = 0
    private var nextNonspace = 0
    private var nextNonspaceColumn = 0
    private var indent = 0
    private var indented = false
    private var blank = false
    private var partiallyConsumedTab = false

    private static let codeIndent = 4

    init() {
        document = Block(.document, line: 0)
        tip = document
        oldTip = document
        lastMatchedContainer = document
    }

    func parse(_ text: String) -> Block {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\u{0}", with: "\u{FFFD}")
        var lines = normalized.components(separatedBy: "\n")
        if normalized.hasSuffix("\n") { lines.removeLast() }
        for line in lines { incorporate(Array(line.utf16)) }
        while tip !== document { finalize(tip) }
        finalize(document)
        return document
    }

    // MARK: - Positions

    private func peek(_ index: Int) -> UInt16? {
        index < line.count ? line[index] : nil
    }

    private func findNextNonspace() {
        var index = offset
        var columns = column
        while index < line.count {
            let character = line[index]
            if character == UInt16(ascii: " ") {
                index += 1
                columns += 1
            } else if character == UInt16(ascii: "\t") {
                index += 1
                columns += 4 - (columns % 4)
            } else {
                break
            }
        }
        blank = index >= line.count
        nextNonspace = index
        nextNonspaceColumn = columns
        indent = nextNonspaceColumn - column
        indented = indent >= Self.codeIndent
    }

    private func advanceNextNonspace() {
        offset = nextNonspace
        column = nextNonspaceColumn
        partiallyConsumedTab = false
    }

    /// Moves forward by characters, or by columns so a tab can be half used.
    private func advanceOffset(_ count: Int, columns: Bool) {
        var remaining = count
        while remaining > 0, offset < line.count {
            if line[offset] == UInt16(ascii: "\t") {
                let toTab = 4 - (column % 4)
                if columns {
                    partiallyConsumedTab = toTab > remaining
                    let advance = min(toTab, remaining)
                    column += advance
                    if !partiallyConsumedTab { offset += 1 }
                    remaining -= advance
                } else {
                    partiallyConsumedTab = false
                    column += toTab
                    offset += 1
                    remaining -= 1
                }
            } else {
                partiallyConsumedTab = false
                offset += 1
                column += 1
                remaining -= 1
            }
        }
    }

    private func addLine() {
        if partiallyConsumedTab {
            offset += 1
            let toTab = 4 - (column % 4)
            tip.content += String(repeating: " ", count: toTab)
        }
        tip.content += string(line, from: offset, to: line.count) + "\n"
    }

    @discardableResult
    private func addChild(_ kind: Block.Kind) -> Block {
        while !tip.canContain(kind) { finalize(tip) }
        let block = Block(kind, line: lineNumber)
        tip.append(block)
        tip = block
        return block
    }

    private func closeUnmatchedBlocks() {
        guard !allClosed else { return }
        while oldTip !== lastMatchedContainer {
            let parent = oldTip.parent
            finalize(oldTip)
            guard let parent else { break }
            oldTip = parent
        }
        allClosed = true
    }

    // MARK: - Lines

    private func incorporate(_ newLine: [UInt16]) {
        line = newLine
        lineNumber += 1
        offset = 0
        column = 0
        blank = false
        partiallyConsumedTab = false
        oldTip = tip

        // 1. Which open containers does this line continue?
        var container = document
        while let child = container.lastChild, child.isOpen {
            container = child
            findNextNonspace()
            switch continues(container) {
            case .matched:
                continue
            case .failed:
                container = container.parent ?? document
            case .lineConsumed:
                return
            }
            break
        }
        allClosed = container === oldTip
        lastMatchedContainer = container

        // 2. Does it start new blocks?
        var matchedLeaf = !container.isParagraph && container.acceptsLines
        while !matchedLeaf {
            findNextNonspace()
            var started = false
            for start in starts {
                let result = start(self, container)
                if result == .container {
                    container = tip
                    started = true
                    break
                } else if result == .leaf {
                    container = tip
                    matchedLeaf = true
                    started = true
                    break
                }
            }
            if !started {
                advanceNextNonspace()
                break
            }
        }

        // 3. Where does the rest of the line go?
        if !allClosed, !blank, tip.isParagraph {
            addLine()  // a lazy continuation line
            return
        }
        closeUnmatchedBlocks()
        if blank, let last = container.lastChild { last.lastLineBlank = true }

        let lastLineBlank: Bool
        switch container.kind {
        case .blockQuote:
            lastLineBlank = false
        case let .codeBlock(fence) where fence != nil:
            lastLineBlank = false
        case .item:
            lastLineBlank = blank && !(container.children.isEmpty && container.startLine == lineNumber)
        default:
            lastLineBlank = blank
        }
        var walker: Block? = container
        while let block = walker {
            block.lastLineBlank = lastLineBlank
            walker = block.parent
        }

        if container.acceptsLines {
            // A fence's own opening line is not part of its content.
            if container.startLine == lineNumber, container.isFencedOrMath { return }
            addLine()
            if case let .htmlBlock(end) = container.kind, case .terminator = end,
               htmlBlockEnds(end, on: line, from: offset) {
                finalize(container)
            }
        } else if offset < line.count, !blank {
            if case .table = container.kind {
                container.rows.append(string(line, from: offset, to: line.count))
            } else {
                addChild(.paragraph)
                advanceNextNonspace()
                addLine()
            }
        }
    }

    // MARK: - Continuation

    private enum Continuation { case matched, failed, lineConsumed }

    private func continues(_ container: Block) -> Continuation {
        switch container.kind {
        case .document, .list:
            return .matched
        case .blockQuote:
            guard !indented, peek(nextNonspace) == UInt16(ascii: ">") else { return .failed }
            advanceNextNonspace()
            advanceOffset(1, columns: false)
            if let next = peek(offset), isSpaceOrTab(next) { advanceOffset(1, columns: true) }
            return .matched
        case let .item(data):
            if blank {
                if container.children.isEmpty { return .failed }
                advanceNextNonspace()
            } else if indent >= data.markerOffset + data.padding {
                advanceOffset(data.markerOffset + data.padding, columns: true)
            } else {
                return .failed
            }
            return .matched
        case .footnote:
            if indent >= Self.codeIndent {
                advanceOffset(Self.codeIndent, columns: true)
            } else if blank {
                advanceNextNonspace()
            } else {
                return .failed
            }
            return .matched
        case .heading, .thematicBreak:
            return .failed
        case let .codeBlock(fence):
            if let fence {
                if indent <= 3, let run = delimiterRun(line, at: nextNonspace, character: fence.character),
                   run.count >= fence.length, isBlank(line, from: run.end) {
                    finalize(container)
                    return .lineConsumed
                }
                var remaining = fence.indent
                while remaining > 0, let next = peek(offset), isSpaceOrTab(next) {
                    advanceOffset(1, columns: true)
                    remaining -= 1
                }
                return .matched
            }
            if indent >= Self.codeIndent {
                advanceOffset(Self.codeIndent, columns: true)
            } else if blank {
                advanceNextNonspace()
            } else {
                return .failed
            }
            return .matched
        case let .htmlBlock(end):
            return blank && end == .blankLine ? .failed : .matched
        case .mathBlock:
            if indent <= 3, isMathFence(line, from: nextNonspace) {
                finalize(container)
                return .lineConsumed
            }
            return .matched
        case .paragraph:
            return blank ? .failed : .matched
        case .table:
            return blank ? .failed : .matched
        }
    }

    // MARK: - Block starts

    private enum StartResult { case none, container, leaf }

    /// Tried in order at each position; the first that matches wins.
    private let starts: [(DocumentParser, Block) -> StartResult] = [
        { $0.startBlockQuote($1) },
        { $0.startATXHeading($1) },
        { $0.startFencedCode($1) },
        { $0.startMathBlock($1) },
        { $0.startHTMLBlock($1) },
        { $0.startTable($1) },
        { $0.startSetextHeading($1) },
        { $0.startThematicBreak($1) },
        { $0.startFootnote($1) },
        { $0.startListItem($1) },
        { $0.startIndentedCode($1) },
    ]

    private func startBlockQuote(_ container: Block) -> StartResult {
        guard !indented, peek(nextNonspace) == UInt16(ascii: ">") else { return .none }
        advanceNextNonspace()
        advanceOffset(1, columns: false)
        if let next = peek(offset), isSpaceOrTab(next) { advanceOffset(1, columns: true) }
        closeUnmatchedBlocks()
        addChild(.blockQuote)
        return .container
    }

    private func startATXHeading(_ container: Block) -> StartResult {
        guard !indented, let heading = atxHeading(line, from: nextNonspace) else { return .none }
        advanceNextNonspace()
        closeUnmatchedBlocks()
        let block = addChild(.heading(level: heading.level))
        let end = heading.closingRange?.location ?? line.count
        block.content = string(line, from: heading.contentStart, to: max(heading.contentStart, end))
        // `#` alone, or `# ###`: the closing run is all there is.
        if heading.closingRange == nil, isOnlyClosingSequence(heading.contentStart) { block.content = "" }
        offset = line.count
        return .leaf
    }

    private func isOnlyClosingSequence(_ start: Int) -> Bool {
        var index = start
        guard index < line.count, line[index] == UInt16(ascii: "#") else { return false }
        while index < line.count, line[index] == UInt16(ascii: "#") { index += 1 }
        return isBlank(line, from: index)
    }

    private func startFencedCode(_ container: Block) -> StartResult {
        guard !indented, let run = delimiterRun(line, at: nextNonspace, character: nil),
              run.character == UInt16(ascii: "`") || run.character == UInt16(ascii: "~"), run.count >= 3
        else { return .none }
        let infoRaw = string(line, from: run.end, to: line.count)
        if run.character == UInt16(ascii: "`"), infoRaw.contains("`") { return .none }
        closeUnmatchedBlocks()
        let info = unescapeLinkText(infoRaw.trimmingCharacters(in: .whitespaces))
        addChild(.codeBlock(fence: Block.Fence(character: run.character, length: run.count, indent: indent, info: info)))
        offset = line.count
        return .leaf
    }

    private func startMathBlock(_ container: Block) -> StartResult {
        guard !indented, nextNonspace + 1 < line.count,
              line[nextNonspace] == UInt16(ascii: "$"), line[nextNonspace + 1] == UInt16(ascii: "$")
        else { return .none }
        if isMathFence(line, from: nextNonspace) {
            closeUnmatchedBlocks()
            addChild(.mathBlock)
            offset = line.count
            return .leaf
        }
        // `$$ … $$` on one line.
        var end = line.count
        while end > nextNonspace, isSpaceOrTab(line[end - 1]) { end -= 1 }
        guard end - nextNonspace > 4, line[end - 1] == UInt16(ascii: "$"), line[end - 2] == UInt16(ascii: "$") else { return .none }
        closeUnmatchedBlocks()
        let block = addChild(.mathBlock)
        block.content = string(line, from: nextNonspace + 2, to: end - 2) + "\n"
        finalize(block)
        offset = line.count
        return .leaf
    }

    private func startHTMLBlock(_ container: Block) -> StartResult {
        // Only the first six kinds may interrupt a paragraph, lazily continued ones included.
        let afterParagraph = container.isParagraph || (!allClosed && !blank && tip.isParagraph)
        guard !indented, peek(nextNonspace) == UInt16(ascii: "<"),
              let end = htmlBlockStart(line, from: nextNonspace, afterParagraph: afterParagraph)
        else { return .none }
        closeUnmatchedBlocks()
        addChild(.htmlBlock(end: end))
        return .leaf  // the line itself is added by the caller, leading spaces and all
    }

    /// GFM: a paragraph's last line followed by a delimiter row with the same
    /// number of cells is a table header.
    private func startTable(_ container: Block) -> StartResult {
        guard !indented, container.isParagraph, contains(line, from: nextNonspace, character: UInt16(ascii: "|")),
              let alignments = tableDelimiter(line, from: nextNonspace)
        else { return .none }
        var paragraphLines = container.content.components(separatedBy: "\n")
        if paragraphLines.last == "" { paragraphLines.removeLast() }
        guard let header = paragraphLines.last,
              MarkdownTable.cells(of: header).count == alignments.count
        else { return .none }
        closeUnmatchedBlocks()
        let table = Block(.table(alignments: alignments), line: lineNumber)
        table.rows = [header]
        paragraphLines.removeLast()
        if paragraphLines.isEmpty {
            table.insertAfter(container)
            container.remove()
        } else {
            container.content = paragraphLines.joined(separator: "\n") + "\n"
            finalize(container)
            table.insertAfter(container)
        }
        tip = table
        offset = line.count
        return .leaf
    }

    private func startSetextHeading(_ container: Block) -> StartResult {
        guard !indented, container.isParagraph, let level = setextLevel(line, from: nextNonspace) else { return .none }
        closeUnmatchedBlocks()
        // Definitions at the start of the paragraph are not part of the heading.
        stripReferenceDefinitions(from: container)
        guard !container.content.isEmpty else { return .none }
        let heading = Block(.heading(level: level), line: container.startLine)
        heading.content = container.content
        heading.insertAfter(container)
        container.remove()
        tip = heading
        offset = line.count
        return .leaf
    }

    private func startThematicBreak(_ container: Block) -> StartResult {
        guard !indented, isThematicBreak(line, from: nextNonspace) else { return .none }
        closeUnmatchedBlocks()
        addChild(.thematicBreak)
        offset = line.count
        return .leaf
    }

    private func startFootnote(_ container: Block) -> StartResult {
        // Like the editor, a definition may follow other lines directly, such
        // as a run of link definitions.
        guard !indented, let footnote = footnoteDefinition(line, from: nextNonspace) else { return .none }
        closeUnmatchedBlocks()
        addChild(.footnote(label: footnote.label))
        references.footnotes.insert(normalizeLabel(footnote.label))
        advanceNextNonspace()
        advanceOffset(footnote.labelEnd - nextNonspace, columns: false)
        return .container
    }

    private func startListItem(_ container: Block) -> StartResult {
        let inList: Bool = if case .list = container.kind { true } else { false }
        guard !indented || inList, var data = parseListMarker(container) else { return .none }
        closeUnmatchedBlocks()
        let continuesList: Bool = if case let .list(existing) = tip.kind, listsMatch(existing, data) { true } else { false }
        if !continuesList {
            data.tight = true
            addChild(.list(data))
        }
        addChild(.item(data))
        return .container
    }

    private func startIndentedCode(_ container: Block) -> StartResult {
        guard indented, !tip.isParagraph, !blank else { return .none }
        advanceOffset(Self.codeIndent, columns: true)
        closeUnmatchedBlocks()
        addChild(.codeBlock(fence: nil))
        return .leaf
    }

    // MARK: - Lists

    private func parseListMarker(_ container: Block) -> Block.ListData? {
        guard indent < Self.codeIndent, nextNonspace < line.count else { return nil }
        let first = line[nextNonspace]
        var markerLength = 0
        var data = Block.ListData(ordered: false, bullet: 0, delimiter: 0, start: 1, markerOffset: indent, padding: 0)

        if first == UInt16(ascii: "-") || first == UInt16(ascii: "+") || first == UInt16(ascii: "*") {
            data.bullet = first
            markerLength = 1
        } else {
            var cursor = nextNonspace
            while cursor < line.count, isASCIIDigit(line[cursor]), cursor - nextNonspace < 9 { cursor += 1 }
            guard cursor > nextNonspace, cursor < line.count,
                  line[cursor] == UInt16(ascii: ".") || line[cursor] == UInt16(ascii: ")")
            else { return nil }
            let number = Int(string(line, from: nextNonspace, to: cursor)) ?? 1
            // Only a list starting at 1 may interrupt a paragraph.
            if container.isParagraph, number != 1 { return nil }
            data.ordered = true
            data.start = number
            data.delimiter = line[cursor]
            markerLength = cursor + 1 - nextNonspace
        }

        let afterMarker = nextNonspace + markerLength
        if let next = peek(afterMarker), !isSpaceOrTab(next) { return nil }
        // An empty item may not interrupt a paragraph.
        if container.isParagraph, isBlank(line, from: afterMarker) { return nil }

        advanceNextNonspace()
        advanceOffset(markerLength, columns: true)
        let spacesStartColumn = column
        let spacesStartOffset = offset
        repeat {
            advanceOffset(1, columns: true)
        } while column - spacesStartColumn < 5 && peek(offset).map(isSpaceOrTab) == true
        let blankItem = peek(offset) == nil
        let spacesAfterMarker = column - spacesStartColumn
        if spacesAfterMarker >= 5 || spacesAfterMarker < 1 || blankItem {
            // Content starting with a code indent, or no content: one space of padding.
            data.padding = markerLength + 1
            column = spacesStartColumn
            offset = spacesStartOffset
            partiallyConsumedTab = false
            if let next = peek(offset), isSpaceOrTab(next) { advanceOffset(1, columns: true) }
        } else {
            data.padding = markerLength + spacesAfterMarker
        }
        return data
    }

    private func listsMatch(_ a: Block.ListData, _ b: Block.ListData) -> Bool {
        a.ordered == b.ordered && a.delimiter == b.delimiter && a.bullet == b.bullet
    }

    // MARK: - Finalizing

    private func finalize(_ block: Block) {
        let parent = block.parent
        block.isOpen = false
        switch block.kind {
        case .paragraph:
            stripReferenceDefinitions(from: block)
            if block.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { block.remove() }
        case let .codeBlock(fence) where fence == nil:
            // Trailing blank lines are not part of an indented block.
            var lines = block.content.components(separatedBy: "\n")
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            block.content = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        case var .list(data):
            data.tight = isTight(block)
            block.kind = .list(data)
        default:
            break
        }
        if let parent { tip = parent }
    }

    private func isTight(_ list: Block) -> Bool {
        for (index, item) in list.children.enumerated() {
            let hasNext = index + 1 < list.children.count
            if hasNext, endsWithBlankLine(item) { return false }
            for (subIndex, child) in item.children.enumerated() {
                let childHasNext = subIndex + 1 < item.children.count
                if endsWithBlankLine(child), hasNext || childHasNext { return false }
            }
        }
        return true
    }

    private func endsWithBlankLine(_ block: Block) -> Bool {
        var current: Block? = block
        while let block = current {
            if block.lastLineBlank { return true }
            switch block.kind {
            case .list, .item: current = block.lastChild
            default: return false
            }
        }
        return false
    }

    // MARK: - Link reference definitions

    /// Takes definitions off the front of a paragraph, recording each.
    private func stripReferenceDefinitions(from paragraph: Block) {
        var characters = Array(paragraph.content.utf16)
        while characters.first == UInt16(ascii: "["),
              let definition = referenceDefinition(characters) {
            let key = normalizeLabel(definition.label)
            if references.links[key] == nil {
                references.links[key] = LinkDefinition(destination: definition.destination, title: definition.title)
            }
            characters = Array(characters[definition.end...])
        }
        paragraph.content = String(decoding: characters, as: UTF16.self)
    }

    /// `[label]: destination "title"`, possibly across lines, at the start.
    private func referenceDefinition(_ characters: [UInt16]) -> (label: String, destination: String, title: String?, end: Int)? {
        let limit = characters.count
        guard let label = parseLinkLabel(characters, at: 0, limit: limit),
              isValidLabel(label.label), !label.label.hasPrefix("^"),
              label.end < limit, characters[label.end] == UInt16(ascii: ":")
        else { return nil }
        var cursor = skipSpacesAndOneNewline(characters, from: label.end + 1)
        guard let destination = parseLinkDestination(characters, at: cursor, limit: limit) else { return nil }
        // A bare destination must not be empty; `<>` may be.
        if destination.end == cursor { return nil }
        cursor = destination.end

        let beforeTitle = cursor
        cursor = skipSpacesAndOneNewline(characters, from: cursor)
        if cursor > beforeTitle, let parsed = parseLinkTitle(characters, at: cursor, limit: limit),
           let lineEnd = restOfLineIsBlank(characters, from: parsed.end) {
            return (label.label, destination.value, parsed.title, lineEnd)
        }
        // Without a usable title, the destination must end its line.
        guard let lineEnd = restOfLineIsBlank(characters, from: beforeTitle) else { return nil }
        return (label.label, destination.value, nil, lineEnd)
    }

    private func skipSpacesAndOneNewline(_ characters: [UInt16], from start: Int) -> Int {
        var cursor = start
        while cursor < characters.count, isSpaceOrTab(characters[cursor]) { cursor += 1 }
        if cursor < characters.count, characters[cursor] == 0x0A {
            cursor += 1
            while cursor < characters.count, isSpaceOrTab(characters[cursor]) { cursor += 1 }
        }
        return cursor
    }

    /// The index after the line ending if only spaces remain on the line.
    private func restOfLineIsBlank(_ characters: [UInt16], from start: Int) -> Int? {
        var cursor = start
        while cursor < characters.count, isSpaceOrTab(characters[cursor]) { cursor += 1 }
        if cursor == characters.count { return cursor }
        return characters[cursor] == 0x0A ? cursor + 1 : nil
    }
}

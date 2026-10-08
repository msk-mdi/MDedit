/// Syntax beyond CommonMark and GFM tables, tasks and strikethrough, each of
/// which can be switched off in Settings for documents that mean the
/// characters literally — `$` in prose about prices, `~` in paths.
public struct SyntaxExtensions: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// `==marked==` text.
    public static let highlight = SyntaxExtensions(rawValue: 1 << 0)
    /// `^super^` and single-`~` `~sub~` scripts.
    public static let scripts = SyntaxExtensions(rawValue: 1 << 1)
    /// `:emoji:` shortcodes.
    public static let emoji = SyntaxExtensions(rawValue: 1 << 2)
    /// `$…$` and `$$…$$` TeX, inline and as blocks.
    public static let math = SyntaxExtensions(rawValue: 1 << 3)
    /// GFM's `https://…` and `www.…` links without angle brackets.
    public static let bareURLs = SyntaxExtensions(rawValue: 1 << 4)
    /// A term on its own line followed by `: definition` lines.
    public static let definitionLists = SyntaxExtensions(rawValue: 1 << 5)

    public static let all: SyntaxExtensions = [.highlight, .scripts, .emoji, .math, .bareURLs, .definitionLists]
}

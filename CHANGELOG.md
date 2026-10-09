# Changelog

Versions follow the milestones in [ROADMAP.md](ROADMAP.md). The release
workflow publishes the section for a version as its release notes.

## [Unreleased]

### Changed
- Homebrew installs MdEdit as a cask: the release's app goes into /Applications,
  ready to open, with the `mdedit` command; no Xcode or build needed.

## [0.9.1] - 2026-10-09

### Fixed
- Building with Xcode 26 and its Command Line Tools, as the Homebrew formula and
  GitHub's macOS 26 runners do: a macOS 27 glass API is now guarded at compile time.
  0.9.0 built only with Xcode 27, so its release was never published.

### Changed
- CI reports compiler errors and test failures as annotations, readable without
  signing in to GitHub.

## [0.9.0] - 2026-10-09

Quality, accessibility and distribution (roadmap P3).

### Added
- VoiceOver reads the editor as it is drawn: hidden markers are skipped, bullets
  and task boxes read as such, emoji shortcodes as their emoji, formulas and
  diagrams as their source, and image lines announce themselves. The tab strip
  is a tab group with the unsaved state in each tab's name and a Close action.
- Quick Look previews of markdown files in Finder.
- MdEdit registers as the default editor for markdown, with its own document icon.
- Help ▸ Welcome to MdEdit (shown on first launch) and Help ▸ Markdown Cheat Sheet,
  both opened as editable copies.
- Check for Updates… in the app menu, and an optional daily check (Settings ▸ Editor).
- Localization: every user-facing string is localizable, collected into
  `Resources/Localizable.xcstrings` by `Scripts/update-strings.sh`.
- Distribution without a paid Apple account: a Homebrew formula that builds MdEdit
  from source (so Gatekeeper never stops it), and a DMG on GitHub Releases with
  first-launch instructions, built by a tag-triggered workflow. Developer ID signing,
  notarization and an App Sandbox build (`--sandbox`, with security-scoped bookmarks
  for the session and workspace folders) are scripted for if that changes.
- CI on macOS 26: build, test, lint (`Scripts/lint.sh`, swift-format) and app assembly.
- Tests for the Format commands, undo, window flows (closing and quitting with
  unsaved tabs, tab tear-off), typing through real key events, and large files.

### Changed
- Each document keeps its own undo history; Format, table, paste and revert edits
  are undo steps of their own, named for the command.
- Typing in large documents: two whole-document walks per keystroke are gone
  (2 MB: 6.8 → 2.0 ms a keystroke), and fonts are built once instead of per line.
- Session restore follows files renamed or moved since the last run.

### Fixed
- Undo in one tab could undo an edit in another tab of the same window.
- Undoing a list continuation, auto-paired bracket, indent or fence close threw an
  exception: each was recorded twice.
- `- ` right after a list item was read as a heading underline, turning the item
  above into a heading and stopping Return from ending the list.

## [0.6.0] - 2026-10-08

Workspaces and power features (roadmap P1–P2): file tree, outline, Quick Open,
Find in Folder, multiple windows and tab tear-off; settings, themes and theme
files; export options, paginated PDF and print, Word/RTF/text, Pandoc and the
`--render` command line; statistics and word goals, folding, several carets,
table of contents and version history; math and Mermaid typeset in the editor.

## [0.5.0]

Tables and math: table editing, inline and display math, Mermaid in export.

## [0.4.0]

Rich editing: inline images, clickable tasks and links, image paste and drop,
rich-text paste, source mode, code block language picker.

## [0.3.0]

Complete syntax: reference links, footnotes, front matter, HTML blocks, bare
autolinks, highlights, sub/superscript, emoji, and the CommonMark spec suite.

## [0.2.0]

Safe: unsaved-change review on quit and close, autosave and crash recovery,
session restore, encoding and line-ending fidelity.

## [0.1.0]

The in-place WYSIWYG editor: incremental parsing, concealed markers, tabs, find
and replace, formatting commands, typewriter and focus modes, HTML and PDF export.

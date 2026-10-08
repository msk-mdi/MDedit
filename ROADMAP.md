# MdEdit roadmap: from v0.1 to a complete markdown editor

## Context
MdEdit is a native macOS (Swift, AppKit/TextKit 1, no dependencies) in-place WYSIWYG editor.
At v0.1 it had an incremental block parser + inline parser (`Sources/MarkdownKit`), concealed-marker
rendering (`MarkdownTextStorage`, `MarkdownLayoutManager`), tabs, find/replace, formatting commands,
list continuation, typewriter/focus mode, file watching, HTML/PDF export, a 3-option settings window,
and 47 tests. The README's own "Not implemented" list plus a code survey gave the gaps below.
Ordered by priority: P0 = data-safety / correctness, P1 = core parity with MarkText/Typora, P2 = power features, P3 = polish & distribution.

**Status (2026-10-08):** P0, P1 and P2 are done — 16 commits, 154 tests, CommonMark 650/652. P3 is not started.

---

## P0 — Don't lose work ✅ (`32c7d9c`)
- [x] **Unsaved changes are lost on ⌘Q and on closing the window.** Quit and window close now review every unsaved tab.
- [x] **Autosave + crash recovery**: unsaved buffers are snapshotted to Application Support and restored on launch.
- [x] **Session restore**: previous tabs, selected tab and caret positions reopen (per window since `0ce6a8d`).
- [x] **Encoding/line-ending fidelity**: original encoding, BOM and CRLF are preserved; a file deleted under the watcher marks the tab unsaved.
- [x] **Save panel**: allows `.markdown`, `.mdown`, `.mkd`, `.txt`.
- [x] **Help menu** points to the MdEdit repository.

## P1 — Markdown coverage ✅
- [x] Reference-style links/images (`5712791`).
- [x] Footnotes (`5712791`).
- [x] YAML front matter (`5712791`).
- [x] HTML blocks (`5712791`).
- [x] Highlight `==mark==` (`5712791`); sub/superscript and emoji shortcodes (`fa251c4`). Not behind toggles — see P2 settings.
- [x] GFM bare-URL autolinks (`5712791`).
- [x] Hard line breaks (`5712791`).
- [x] Math: inline `$…$` and block `$$…$$` — styled in the editor, KaTeX in HTML export (`fa251c4`). No in-editor typesetting.
- [x] Mermaid fences in HTML export (`fa251c4`). No in-editor preview.
- [x] CommonMark conformance suite (`00ccee4`), raised from 376 to 650/652 with a spec-exact inline parser and an export-only `DocumentParser` (`b8af344`). The two failures are deliberate bare-URL autolinks.

## P1 — In-editor rendering & interaction ✅
- [x] **Inline image previews** (`9c4b31c`) — drawn by the layout manager in space reserved with `minimumLineHeight`, not `NSTextAttachment`, so the source stays plain markdown.
- [x] **Table editing** (`3ac60bf`) — Tab/⇧Tab cells, Return rows, Format ▸ Table commands, auto-alignment, grid look. Source stays pipe tables rather than a true grid.
- [x] Clickable task checkboxes (`9c4b31c`).
- [x] ⌘-click links, hover tooltips, local `.md` links open in a tab, `#heading` anchors (`9c4b31c`).
- [x] Auto-pair `(`, `[`, `{` and backticks, plus paste a URL over a selection to make a link (`e6f471a`). `*`/`_` deliberately not paired.
- [x] Paste/drop images; pasted data saved to `assets/` (`e6f471a`).
- [x] Paste rich text/HTML → markdown (`54dd108`).
- [x] Code blocks: language picker, Copy button, fence auto-close, kept indentation (`0aedd06`).
- [x] Source mode toggle, ⌘/ (`e6f471a`).

## P1 — Navigation & files ✅
- [x] **Outline sidebar** (`e66e8c5`).
- [x] **File tree sidebar** and Quick Open, ⌘P (`fe8ce64`).
- [x] Find in Folder, ⇧⌘F (`fe8ce64`).
- [x] Drag tabs to reorder, drop markdown files to open (`bb3593b`); drag a tab out into a new window (`0ce6a8d`).
- [x] Multiple windows (`0ce6a8d`).

## P2 — Settings & theming ✅ (`b430e88`)
- [x] Theme picker: Default, Paper, Solarized, Nord (light + dark each); CSS-like `.mdtheme` files in Application Support, reloaded on save; separate code palette (Xcode, GitHub, Solarized, Nord, Monokai).
- [x] Line height, space after blocks, padding, code font.
- [x] Toggles: smart quotes (never in code), spell check, typewriter/focus defaults, each extended syntax (`SyntaxExtensions` in MarkdownKit, editor and export), bullet marker, ordered numbering (1. 2. 3. / 1. 1. 1.), numbered headings.
- [x] View modes (source/typewriter/focus) persist per tab in the session.
- [x] Zoom ⌘+ / ⌘- / ⌘0.
- Also fixed: settings now apply to open windows immediately (nothing observed `settingsDidChange` before).

## P2 — Export & interop ✅ (`93b191d`)
- [x] Export options (remembered): theme, stylesheet on/off, embedded images, TOC; PDF paper size, margins, title + page-number header/footer.
- [x] Word (.docx), RTF, plain text via `NSAttributedString`; Pandoc (EPUB, ODT, LaTeX, Typst, …) when installed.
- [x] Print ⌥⌘P with real pagination: a separate layout at paper width, breaking between lines.
- [x] Images as data URIs for self-contained HTML.
- [x] Copy as Rich Text (⌥⇧⌘C).
- [x] `--render`: stdin, `--output`, `--standalone`, `--theme`, `--toc`, `--number-headings`, `--embed-images`.
- [~] Offline KaTeX/Mermaid: `Scripts/fetch-vendor.sh` + bundling + inlining are in place; the vendor files have not been downloaded (run the script).
- Also fixed: the line parser kept a list open after a blank line, indenting a following heading/paragraph.

## P2 — Writing tools ✅ (`138fc8f`)
- [x] Status bar selection count, statistics popover (⇧⌘I), per-file word goal with progress.
- [x] Heading fold/collapse (⌥⌘← / ⌥⌘→, ⌃ for all), clickable ⋯ chip.
- [x] Several carets: ⌥-click, ⌃⇧↑/↓, ⌘D next occurrence, ⌃⌘G all occurrences, column selection typing — one undo step.
- [x] Format ▸ Table of Contents (linked list); `[TOC]` and numbered headings in export.
- [x] Version history on open/save + macOS `NSFileVersion`s; File ▸ Revert To ▸ Last Saved / Browse Versions….

## P3 — Quality, accessibility, performance
- [ ] VoiceOver: make concealed markers and custom glyph substitutions (`•`, `☑`, emoji) read sensibly; tab bar accessibility labels.
- [ ] Large-file performance benchmarks (e.g. 5 MB / 100k lines) and profiling of `processEditing` + `drawBackground`.
- [ ] More tests — partly done: persistence, rich editing, tables, code blocks, workspace, HTML paste and fuzzing were added along the way. Still missing: `MarkdownCommands`, window-level flows (quit review, tab tear-off), UI tests that drive real input.
- [ ] CI (GitHub Actions on macOS 26 runner): `swift build`, `swift test`, lint (SwiftLint/swift-format).
- [ ] Localization scaffolding (strings are hard-coded English).
- [ ] Undo grouping review for formatting commands and auto-continuation.

## P3 — Distribution
- [ ] Developer ID signing + notarization in `Scripts/make-app.sh`; App Sandbox with security-scoped bookmarks (needed for recents, session restore and workspaces once sandboxed).
- [ ] Auto-update (Sparkle) or Mac App Store build.
- [ ] Register as a handler for `.md` with a proper UTI/icon; Quick Look preview extension for `.md` files (reuse `MarkdownKit` HTML renderer).
- [ ] Homebrew cask, release workflow producing a DMG, CHANGELOG, bump `CFBundleShortVersionString` from 0.1.
- [ ] Real Help: in-app markdown cheat sheet / welcome document on first launch.

---

## Milestones
1. ✅ **v0.2 "Safe"** — all P0 items.
2. ✅ **v0.3 "Complete syntax"** — reference links, footnotes, front matter, HTML blocks, bare autolinks, CommonMark suite.
3. ✅ **v0.4 "Rich editing"** — image previews, clickable tasks/links, image paste, outline sidebar, source mode.
4. ✅ **v0.5 "Tables & math"** — table editor, math, mermaid in export.
5. ✅ **v0.6 "Workspace"** — file tree, quick open, multi-window, settings, export and writing tools (P2).
6. ☐ **v1.0** — accessibility pass, tests/CI, signing, notarization, auto-update, Quick Look.

## Known gaps carried forward
- Not exercised with real input (macOS blocked synthetic keystrokes and drags from the dev session): the new Settings window, export panels and Print, fold chips, ⌥-click carets, the version browser, Quick Open, Find in Folder typing, tab dragging and tear-off, image/HTML paste from other apps, code-block menu and Copy, the quit prompt across several windows.
- The editor and export can disagree on non-line-local CommonMark (e.g. a paragraph inside a list item after a blank line): the editor's `BlockParser` is line-based by design.
- A renamed file is not followed; the tab is marked unsaved and saving recreates the old path.

## Verification (per item when implemented)
- `swift test` (extend the incremental-reparse equivalence fuzz test for every new block construct; keep `CommonMarkSpecTests` at or above its baseline).
- `Scripts/make-app.sh && open build/MdEdit.app` and exercise the feature manually.

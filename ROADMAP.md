# MdEdit roadmap: from v0.1 to a complete markdown editor

## Context
MdEdit is a native macOS (Swift, AppKit/TextKit 1, no dependencies) in-place WYSIWYG editor.
At v0.1 it had an incremental block parser + inline parser (`Sources/MarkdownKit`), concealed-marker
rendering (`MarkdownTextStorage`, `MarkdownLayoutManager`), tabs, find/replace, formatting commands,
list continuation, typewriter/focus mode, file watching, HTML/PDF export, a 3-option settings window,
and 47 tests. The README's own "Not implemented" list plus a code survey gave the gaps below.
Ordered by priority: P0 = data-safety / correctness, P1 = core parity with MarkText/Typora, P2 = power features, P3 = polish & distribution.

**Status (2026-10-08):** P0–P3 are done — 208 tests, CommonMark 650/652. What v1.0 still needs is outside the code: a Developer ID to sign and notarize a release, and a tap for the cask.

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
- [x] Math: inline `$…$` and block `$$…$$` — KaTeX in HTML export (`fa251c4`), and typeset in the editor: a hidden `WKWebView` (`Typesetter`) snapshots KaTeX output, drawn by the layout manager — inline on a kerned anchor glyph, blocks in reserved line height. The caret in a block shows its source with a live preview below.
- [x] Mermaid fences in HTML export (`fa251c4`) and drawn in the editor the same way as display math.
- [x] Definition lists (`Term` / `: definition`, a toggleable extension) in the editor and as `<dl>` in export; `<kbd>` drawn as key chips in the editor.
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
- [~] Offline KaTeX/Mermaid: `Scripts/fetch-vendor.sh` + bundling + inlining are in place, for export and for the editor's typesetting (which falls back to jsDelivr without them). The vendor files are not committed; run the script before `make-app.sh`.
- Also fixed: the line parser kept a list open after a blank line, indenting a following heading/paragraph.

## P2 — Writing tools ✅ (`138fc8f`)
- [x] Status bar selection count, statistics popover (⇧⌘I), per-file word goal with progress.
- [x] Heading fold/collapse (⌥⌘← / ⌥⌘→, ⌃ for all), clickable ⋯ chip.
- [x] Several carets: ⌥-click, ⌃⇧↑/↓, ⌘D next occurrence, ⌃⌘G all occurrences, column selection typing — one undo step.
- [x] Format ▸ Table of Contents (linked list); `[TOC]` and numbered headings in export.
- [x] Version history on open/save + macOS `NSFileVersion`s; File ▸ Revert To ▸ Last Saved / Browse Versions….

## P3 — Quality, accessibility, performance ✅
- [x] **VoiceOver** (`91b05e7`): the text view answers VoiceOver's string-for-range questions with what is drawn — concealed markers skipped, `•` for bullets, "checked"/"unchecked" for task boxes, emoji for shortcodes, TeX or diagram source for typeset images, "Image" before an image line — in storage offsets, so the caret VoiceOver tracks still matches. Tabs are radio-button tabs in a tab group, "edited" in the name, Close Tab as an action.
- [x] **Large-file benchmarks** (`3d26542`): `PerformanceTests`, a 10k-line run always and 100k lines / ~5 MB with `MDEDIT_BENCHMARKS=1`. Profiling found AppKit's attribute fixing walking the whole document twice per keystroke (glyph-info search, `length` via `string`); fonts are cached. Release, 100k lines / 2 MB: keystroke 6.8 → 2.0 ms, load 4.0 → 3.2 s. What is left is Foundation's flat run array (a memmove per attribute change, ~4 ms per keystroke at 4.5 MB) and contiguous layout (5.6 s to lay out to the middle of 4.5 MB on first scroll there); both need a different storage or non-contiguous layout.
- [x] **More tests** (`4152fca`, `f6d72cc`): every Format command and its undo, window flows (close with Cancel / Don't Save / Save, quit across windows, tear-off keeping text and undo) behind an injectable save prompt, and `KeyboardInputTests`, which send real key events through a window. They found the three bugs below. XCUITest-style tests of the running app still need an Xcode project.
- [x] **CI** (`71cd4c9`): GitHub Actions on `macos-26` — build, test, `Scripts/lint.sh` (swift-format; layout findings left out, as the pretty-printer would reflow hand-laid tables), release app assembly. Not yet run on GitHub.
- [x] **Localization scaffolding** (`69e7f7e`): ~250 strings through `String(localized:)` (menu titles as `String.LocalizationValue`), extracted by the compiler with `Scripts/update-strings.sh` into `Resources/Localizable.xcstrings`, compiled into the bundle by `make-app.sh`. No translations yet.
- [x] **Undo grouping** (`4152fca`): per-document undo managers (tabs shared the window's — undo could hit another tab); input-handler edits were registered twice and threw on undo; commands are named steps that don't coalesce with typing.
- Also fixed: `- ` after a list item parsed as a setext underline (`f6d72cc`).

## P3 — Distribution ✅ (scripted; needs an Apple Developer ID to run for real)
- [x] Developer ID signing (hardened runtime) and notarization in `Scripts/make-app.sh` from `MDEDIT_SIGN_IDENTITY` / `MDEDIT_NOTARY_PROFILE`; `--sandbox` signs with App Sandbox entitlements. `FileAccess` keeps bookmarks (security-scoped when sandboxed) for opened files and workspace folders and resolves the session through them — which also follows files renamed between launches. Recents use `NSDocumentController`'s own. The sandboxed build has not been launched.
- [~] Auto-update: Check for Updates… and an opt-out daily check against GitHub Releases, opening the release page. No Sparkle (it would be the first dependency) and no Mac App Store build (needs an account).
- [x] Markdown UTI declared, MdEdit the default handler, document icon (`make-icon.swift` draws both). Quick Look preview extension (`Sources/MdEditQuickLook`, a SwiftPM executable entered at `NSExtensionMain`, wrapped as an `.appex` by `make-app.sh`) renders with `MarkdownKit` and its own light/dark stylesheet — checked with `qlmanage -p`.
- [x] `Scripts/make-dmg.sh`, `.github/workflows/release.yml` (tag `v*` → test, vendor, sign, notarize, DMG, GitHub release with the CHANGELOG section), `Packaging/Homebrew/mdedit.rb`, `CHANGELOG.md`, version 0.9.0 with the commit count as build number.
- [x] Help: Welcome page on first launch and a Markdown Cheat Sheet, opened as editable untitled copies; MdEdit on GitHub.

---

## Milestones
1. ✅ **v0.2 "Safe"** — all P0 items.
2. ✅ **v0.3 "Complete syntax"** — reference links, footnotes, front matter, HTML blocks, bare autolinks, CommonMark suite.
3. ✅ **v0.4 "Rich editing"** — image previews, clickable tasks/links, image paste, outline sidebar, source mode.
4. ✅ **v0.5 "Tables & math"** — table editor, math, mermaid in export.
5. ✅ **v0.6 "Workspace"** — file tree, quick open, multi-window, settings, export and writing tools (P2).
6. ✅ **v0.9** — accessibility, tests and CI, undo, localization scaffolding, Quick Look, signing and release scripts.
7. ☐ **v1.0** — the first signed, notarized release; translations.

## Known gaps carried forward
- Not exercised with real input (macOS blocked synthetic keystrokes and drags from the dev session): the new Settings window, export panels and Print, fold chips, ⌥-click carets, the version browser, Quick Open, Find in Folder typing, tab dragging, image/HTML paste from other apps, code-block menu and Copy. Typing, list and table keys, the quit review and tear-off are now covered by tests.
- The editor and export can disagree on non-line-local CommonMark (e.g. a paragraph inside a list item after a blank line): the editor's `BlockParser` is line-based by design.
- A file renamed while open is not followed (the tab is marked unsaved and saving recreates the old path); one renamed between launches is, through its bookmark.

## Verification (per item when implemented)
- `swift test` (extend the incremental-reparse equivalence fuzz test for every new block construct; keep `CommonMarkSpecTests` at or above its baseline).
- `Scripts/make-app.sh && open build/MdEdit.app` and exercise the feature manually.

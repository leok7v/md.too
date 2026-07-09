# md.too

A minimalist Markdown viewer for macOS and iOS. Read-only, native, zero third-party dependencies.

## What it does

- Open a `.md` file and see it rendered.
- Read selectably — drag across paragraphs, headings, lists, and quotes and the selection flows continuously the way the document reads. Code blocks, tables, and images select as whole atoms.
- Copy the whole document (Cmd-C or the toolbar Copy button) — paste it as plain text, HTML, RTF, or PDF depending on what the target app accepts.
- Save the document as a paginated PDF (with syntax-highlighted code, embedded images, zebra-striped tables) or as a self-contained HTML file (inline styles only — no external CSS, no JavaScript).
- Toggle between the rendered view and the raw Markdown source from the toolbar.
- macOS Quick Look extension renders `.md` in Finder's preview pane and on spacebar peek.
- Syntax highlighting for about 40 languages (Swift, C/C++/C#/Objective-C, Java, Kotlin, Scala, JS/TS, Python, Rust, Go, Ruby, PHP, Dart, Lua, Perl, R, Julia, Haskell, OCaml, F#, Elixir, Clojure, Groovy, SQL, GraphQL, Dockerfile, Makefile, TOML, INI, YAML, JSON, XML, HTML, CSS, Bash, PowerShell, Markdown).
- Tables with zebra rows, a stronger header band, and inline formatting inside cells — `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `[link](url)`.
- GitHub-style task lists (`- [ ]` / `- [x]`).
- Tiny LaTeX subset in `$…$` / `$$…$$`: Greek letters, super/subscripts, common operators, simple fractions.

See [EXAMPLE.md](EXAMPLE.md) for a single document that exercises every supported feature.

## What it doesn't do

No editor, no live edit/preview split, no autosave. No HTML or `WKWebView`. No file tree, tabs, or command palette. No app-level themes (light/dark follows the system, or pick one explicitly). No third-party packages — pure Swift + AppKit/UIKit/SwiftUI.

For context: the most popular JavaScript Markdown library, `marked`, reports about 636 transitive dependencies and roughly 38,980 lines of code on its public dependency graph. The md.too app is a few Swift files with no dependencies. Every package you do not pull in is a supply-chain risk you do not inherit.

## Toolbar

The toolbar (in both apps, and a reduced cluster in the top-right of the Quick Look pane) carries these actions:

`䷀   ⎘   ⤓ᴘᴅꜰ   ⤓ₕₜₘₗ   ↥   ◐☼☽`

- **䷀ Source** — toggle between the rendered document and the raw Markdown text. Read-only either way; the source view exists so you can copy verbatim Markdown when the destination needs source rather than a formatted paste.
- **⎘ Copy** — copy the whole document to the clipboard with multiple flavors attached:
  - **Plain text** — falls into Terminal, an `<input>` field, or a code editor as readable Markdown-flavored text. Tables are width-aligned ASCII so columns line up.
  - **HTML** — pastes into Mail, Gmail, Notes, or any rich-text editor with bold / italic / code / links / tables / zebra striping preserved. Inline styles only, no `<style>` block, so paste sanitizers leave the formatting alone.
  - **RTF** (macOS) — pastes into TextEdit and other Cocoa rich-text targets.
  - **PDF** — drops a fully laid-out PDF into Pages, Keynote, or Preview. Rendered on demand the first time the target asks for it, so Copy itself stays instant.
- **⤓ᴘᴅꜰ Save as PDF** (macOS) — paginated PDF with embedded images, syntax-highlighted code blocks, zebra-striped tables, page numbers, and the document title in the header. The page size follows your locale (Letter in the US, A4 elsewhere).
- **⤓ₕₜₘₗ Save as HTML** (macOS) — single self-contained `.html` file with all images inlined as base64 and styles attached inline on every element. Theme-neutral grays, no JavaScript, no external references — opens and prints anywhere, survives email, and round-trips through TextEdit's HTML-to-RTF converter.
- **↥ Share** — system Share sheet with a freshly-rendered PDF attached.
- **◐☼☽ Theme** — system / light / dark cycle for the current window only. The document is never modified.

The Quick Look extension shows only the Source and Theme buttons; saving, copying, and sharing happen in the full app.

## Why

A friend asked me last week what a Markdown file is. I had to explain that `.md` is the substrate the work is written on — README, AGENTS, PRD, every issue, every PR — and that I'd just spent a week cycling through half a dozen Electron viewers, each half a gigabyte of TypeScript shipping its own "Pro" upsell modal, and each still failing at a nested list inside a blockquote inside a code fence. So I lifted the Markdown renderer from [an earlier chat-app project](https://im-ai.local-llama.workers.dev/) of mine and made it a real app. The macOS build also exports to a paginated PDF on one click, and the Quick Look extension renders any `.md` in Finder's preview pane and on spacebar peek. The iOS build exists because once the parser and view were portable, it was three Info.plist keys away.

## Download

- iOS / iPadOS — on the [App Store](https://apps.apple.com/us/app/md-too/id6767852877).
- macOS — signed and notarized `.dmg` published as a [GitHub Release](https://github.com/leok7v/md.too/releases/latest) on each tagged version.

## Build from source

Open `md.too.xcodeproj` in Xcode 15+ and pick a scheme:

- `md.too` — the multiplatform app. Pick a macOS or iOS destination in the toolbar; on macOS the Quick Look extension is embedded automatically.
- `md.too QuickLook` — the Quick Look extension on its own; normally not needed.

Or from the command line:

```sh
xcodebuild -project md.too.xcodeproj -scheme "md.too" \
  -destination "generic/platform=macOS" build
xcodebuild -project md.too.xcodeproj -scheme "md.too" \
  -destination "generic/platform=iOS Simulator" build
```

The project ships with no `DEVELOPMENT_TEAM` set, so a fresh clone builds with ad-hoc ("Sign to Run Locally") signing — no Apple Developer account required for local development. To override locally, drop a one-line `Local.xcconfig` next to `Base.xcconfig` containing `LOCAL_DEVELOPMENT_TEAM = YOURTEAMID`; it's gitignored.

## Privacy

[Privacy policy](https://leok7v.github.io/md.too/privacy.html) — short version: the app collects nothing, stores nothing, transmits nothing. The only network requests are HTTPS image fetches for inline images you reference by URL in your own Markdown.

## Demos

A short loop through [EXAMPLE.md](EXAMPLE.md) on each platform — parsing, syntax highlighting, scrolling, theme toggle.

<table>
<tr>
<td align="center" width="35%">
  <img src="docs/videos/md.too.ios.gif" width="240" alt="md.too rendering EXAMPLE.md on iOS"><br>
  <sub><b>iOS</b></sub>
</td>
<td align="center" width="65%">
  <img src="docs/videos/md.too.macos.gif" width="540" alt="md.too rendering EXAMPLE.md on macOS"><br>
  <sub><b>macOS</b></sub>
</td>
</tr>
</table>

## Source code

[`src/`](src) is the whole codebase: 30 hand-written Swift files plus a bundled [`highlights.ini`](src/highlights.ini). No SPM packages, no CocoaPods, no vendored sources. Every file depends only on files in lower layers — the dependency graph is a tree, not a web, and zero `#if os(...)` walls remain anywhere in the source.

The layout is layered. A given file references only symbols from files in layers below it, so reading top-down or bottom-up never requires holding a cycle in your head.

**Layer 0 — leaves, no in-module deps:**

- [`Platform-macOS.swift`](src/Platform-macOS.swift), [`Platform-iOS.swift`](src/Platform-iOS.swift) — typealiases (`PlatformFont`, `PlatformColor`, `PlatformImage`), every `platform*` helper (font traits, colors, decoding, clipboard, light-appearance, PDF thumbnails). `@_exported import AppKit`/`UIKit` so consumers don't restate the framework dependency. Re-routes through a `pdfDataExporter` hook so `CopyPdfProvider` can sit here without dragging in apps-only code.
- [`TeX.swift`](src/TeX.swift) — `$…$` / `$$…$$` LaTeX subset to Unicode/AttributedString.
- [`FileWatcher.swift`](src/FileWatcher.swift) — `NSFilePresenter` wrapper for live file-on-disk reload.
- [`Environment.swift`](src/Environment.swift) — pure SwiftUI primitives: `PrefetchedImagesKey`, `SecondaryTextKey`, `ThemeMode`, `ThemeButton`, `SourceButton`.

**Layer 1 — parser, fonts, highlighter:**

- [`FontRole.swift`](src/FontRole.swift) — `FontRole` enum mapping `.body` / `.heading(n)` / `.mono` to a `PlatformFont`.
- [`MarkdownParser.swift`](src/MarkdownParser.swift) — `Block` enum, `ListItem`, and the block parser with CommonMark container model + link-reference rewrite. Pure data; no SwiftUI.
- [`Highlight.swift`](src/Highlight.swift) — regex syntax highlighter driven by [`highlights.ini`](src/highlights.ini).

**Layer 2 — shared data helpers and selectable text:**

- [`TableMetrics.swift`](src/TableMetrics.swift) — column-width math (counts, char widths, point widths with optional minimums, longest-word, monospace serialization). Used by the on-screen table view, the PDF table renderer, and the HTML/plain exports.
- [`ImagePrefetch.swift`](src/ImagePrefetch.swift) — walks `[Block]` and concurrently fetches remote image URLs.
- [`SelectableText.swift`](src/SelectableText.swift) — `SelectableText` SwiftUI view + `NativeText` builder + the `AtomicKind` / `atomicKindKey` / `atomicIdKey` constants that mark code / table / image runs.

**Layer 3 — bridges and pure-data exporters:**

- [`Bridges-macOS.swift`](src/Bridges-macOS.swift), [`Bridges-iOS.swift`](src/Bridges-iOS.swift) — `NS/UIViewRepresentable` for `NativeText`, plus `WindowAppearanceApplier`. macOS variant also carries the anchor-scope selection arbiter that snaps a drag to whole when it crosses an atomic block (code, table, image).
- [`HtmlExport.swift`](src/HtmlExport.swift) — `[Block]` → self-contained HTML with inline styles.
- [`PlainExport.swift`](src/PlainExport.swift) — `[Block]` → Markdown-flavored plain text, tables width-aligned.

**Layer 4 — block views:**

- [`BlockViews.swift`](src/BlockViews.swift) — per-block SwiftUI render (heading, list, code, table, image, quote, rule). `TableBlock` handles per-column natural-width measurement and graceful overflow.

**Layer 5–6 — single-surface and PDF (apps only):**

- [`DocumentText.swift`](src/DocumentText.swift) — document-wide `NSAttributedString` builder that backs continuous cross-block selection on the single-surface code path.
- [`DocumentText-macOS.swift`](src/DocumentText-macOS.swift), [`DocumentText-iOS.swift`](src/DocumentText-iOS.swift) — platform-specific table layout via `extension DocumentText { static func table(...) }` (`NSTextTable` on macOS, tab-stop paragraphs on iOS).
- [`PDFExport.swift`](src/PDFExport.swift) — entry layer: `TempPDFs`, `prefetchDocumentImages`, `exportPDF` / `exportPDFDataSync`, and the `PDFExport` enum that sets up the `CGContext` and drives the renderer.
- [`PDFRenderer.swift`](src/PDFRenderer.swift) — the `PDFRenderer` class itself: a CT-based page-by-page composer with embedded images, syntax-highlighted code, zebra tables, page numbers.

**Layer 7 — toolbar:**

- [`Toolbar.swift`](src/Toolbar.swift) — `CopyDocButton` (multi-flavor pasteboard with lazy PDF) and `ShareButton`. Apps only.
- [`Toolbar-macOS.swift`](src/Toolbar-macOS.swift) — Save-as-PDF and Save-as-HTML panels. macOS app only.

**Layer 8 — top-level views:**

- [`MarkdownView.swift`](src/MarkdownView.swift) — chrome-less rendering core that routes between source / rendered / single-surface and prefetches inline images. Apps only.
- [`QuickLook.swift`](src/QuickLook.swift) — `QLPreviewingController` plus `QLContent`, a stripped preview view. Quick Look extension only.

**Layer 9 — chrome:**

- [`ContentView-macOS.swift`](src/ContentView-macOS.swift) — wraps `MarkdownView` with the macOS `.toolbar` and `WindowFrameAutosave`. macOS app only.
- [`ContentView-iOS.swift`](src/ContentView-iOS.swift) — wraps `MarkdownView` with the iOS `.safeAreaInset` top bar. iOS app only.

**Layer 10 — entry points:**

- [`MarkdownDocument.swift`](src/MarkdownDocument.swift) — `MarkdownDocument: FileDocument`, the UTType-aware document model that `DocumentGroup` (macOS) and `.fileImporter` (iOS) bind to. Apps only.
- [`App-macOS.swift`](src/App-macOS.swift) — `@main`, `DocumentGroup`, `AppDelegate`, Open-panel seeding. Wires `pdfDataExporter` back to `exportPDFDataSync` so the layer-0 `CopyPdfProvider` can deliver lazy PDF to the pasteboard. macOS app only.
- [`App-iOS.swift`](src/App-iOS.swift) — `@main`, `WindowGroup`, `IOSDocumentRoot` (file importer). iOS app only.

[`config/`](config) holds the three `Info-*.plist` files for the app and extension targets, four `*.entitlements` files (release + debug pairs for the apps and the extension), and `Base.xcconfig` / `version.xcconfig` / a gitignored per-developer `Local.xcconfig`.

## License

MIT.

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
<img width="476" height="68" alt="toolbar-buttons" src="https://github.com/user-attachments/assets/594bba04-aaf5-4a33-9d97-ec8533059f2a" />

- **Source** — <img width="41" height="34" alt="source" src="https://github.com/user-attachments/assets/8bce80c6-e43c-49fe-aa18-22b5dbdef31c" />
toggle between the rendered document and the raw Markdown text. Read-only either way; the source view exists so you can copy verbatim Markdown when the destination needs source rather than a formatted paste.
- **Copy** — <img width="38" height="34" alt="copy" src="https://github.com/user-attachments/assets/64660758-812b-4423-b8ac-9dfcae473f03" />
copy the whole document to the clipboard with multiple flavors attached:
  - **Plain text** — falls into Terminal, an `<input>` field, or a code editor as readable Markdown-flavored text. Tables are width-aligned ASCII so columns line up.
  - **HTML** — pastes into Mail, Gmail, Notes, or any rich-text editor with bold / italic / code / links / tables / zebra striping preserved. Inline styles only, no `<style>` block, so paste sanitizers leave the formatting alone.
  - **RTF** (macOS) — pastes into TextEdit and other Cocoa rich-text targets.
  - **PDF** — drops a fully laid-out PDF into Pages, Keynote, or Preview. Rendered on demand the first time the target asks for it, so Copy itself stays instant.
- **Save as PDF** (macOS) — <img width="37" height="34" alt="save-pdf" src="https://github.com/user-attachments/assets/ce738bdf-2f87-4223-8029-aa3c04222490" />
paginated PDF with embedded images, syntax-highlighted code blocks, zebra-striped tables, page numbers, and the document title in the header. The page size follows your locale (Letter in the US, A4 elsewhere).
- **Save as HTML** (macOS) — <img width="37" height="34" alt="save-html" src="https://github.com/user-attachments/assets/80f67fc7-cf6f-46b7-90ec-31dbcb5d7497" />
single self-contained `.html` file with all images inlined as base64 and styles attached inline on every element. Theme-neutral grays, no JavaScript, no external references — opens and prints anywhere, survives email, and round-trips through TextEdit's HTML-to-RTF converter.
- **Share** — <img width="37" height="34" alt="share" src="https://github.com/user-attachments/assets/8c021dd9-68e9-4f9f-9c8d-53cd9759e852" />
system Share sheet with a freshly-rendered PDF attached.
- **Theme** — <img width="37" height="34" alt="theme" src="https://github.com/user-attachments/assets/36ec6808-8b71-4497-8e0e-4c952e332f74" />
system / light / dark cycle for the current window only. The document is never modified.

The Quick Look extension shows only the Source and Theme buttons; saving, copying, and sharing happen in the full app.

## Why

A friend asked me last week what a Markdown file is. I had to explain that `.md` is the substrate the work is written on — README, AGENTS, PRD, every issue, every PR — and that I'd just spent a week cycling through half a dozen Electron viewers, each half a gigabyte of TypeScript shipping its own "Pro" upsell modal, and each still failing at a nested list inside a blockquote inside a code fence. So I lifted the Markdown renderer from [an earlier chat-app project](https://im-ai.local-llama.workers.dev/) of mine and made it a real app. The macOS build also exports to a paginated PDF on one click, and the Quick Look extension renders any `.md` in Finder's preview pane and on spacebar peek. The iOS build exists because once the parser and view were portable, it was three Info.plist keys away.

## Download

- iOS / iPadOS — on the [App Store](https://apps.apple.com/us/app/md-too/id6767852877).
- macOS — signed and notarized `.dmg` published as a [GitHub Release](https://github.com/leok7v/md.too/releases/latest) on each tagged version.

## Build from source

Open `md.too.xcodeproj` in Xcode 15+ and pick a scheme:

- `md.too macOS` — the macOS app (Quick Look extension is bundled automatically).
- `md.too iOS` — the iOS / iPadOS app.
- `md.too QuickLook` — the Quick Look extension on its own; normally not needed.

Or from the command line:

```sh
xcodebuild -project md.too.xcodeproj -scheme "md.too macOS" build
xcodebuild -project md.too.xcodeproj -scheme "md.too iOS" \
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

[`src/`](src) is the whole codebase: 16 hand-written Swift files plus a bundled [`highlights.ini`](src/highlights.ini). No SPM packages, no CocoaPods, no vendored sources.

Cross-target — compiled into the macOS app, the iOS app, and the Quick Look extension:

- [`MarkdownParser.swift`](src/MarkdownParser.swift) — `MarkdownDocument` (FileDocument), block parser with CommonMark container model, tiny LaTeX subset.
- [`MarkdownView.swift`](src/MarkdownView.swift) — top-level SwiftUI view; composes the toolbar and routes between rendered, source, and the single-text-surface paths.
- [`BlockViews.swift`](src/BlockViews.swift) — per-block render (heading, list, code, table, image), plus `TableMetrics` (the shared column-width primitive used by the on-screen, PDF, and HTML table renderers).
- [`SelectableText.swift`](src/SelectableText.swift) — selectable / copyable text wrapper around `NSTextView` / `UITextView`.
- [`Highlight.swift`](src/Highlight.swift) — regex syntax highlighter, driven by [`highlights.ini`](src/highlights.ini).
- [`Platform.swift`](src/Platform.swift), [`FontRole.swift`](src/FontRole.swift), [`Environment.swift`](src/Environment.swift) — typealiases, font / theme support, image prefetch, and the small Source / Theme toolbar buttons.

Apps only — macOS + iOS, not the Quick Look extension:

- [`App.swift`](src/App.swift) — `@main`, `DocumentGroup`, Open-panel seeding.
- [`AppShell.swift`](src/AppShell.swift) — on-disk file-change watcher, window-frame autosave, system-theme bridge.
- [`Toolbar.swift`](src/Toolbar.swift) — Copy (multi-flavor pasteboard with lazy PDF) and Share buttons.
- [`PDFRenderer.swift`](src/PDFRenderer.swift) — paginated PDF export, theme-neutral HTML export, plain-text export, and `DocumentText` (the document-wide single text surface that backs continuous cross-block selection).

Per platform / per target:

- [`Bridges-macOS.swift`](src/Bridges-macOS.swift) — `NSViewRepresentable` for selectable text, plus the anchor-scope selection arbiter that snaps a drag to whole when it crosses an atomic block (code, table, image). macOS app + Quick Look extension.
- [`Bridges-iOS.swift`](src/Bridges-iOS.swift) — `UIViewRepresentable` for selectable text. iOS app only.
- [`Toolbar-macOS.swift`](src/Toolbar-macOS.swift) — Save-as-PDF and Save-as-HTML panels. macOS app only.
- [`QuickLook.swift`](src/QuickLook.swift) — `QLPreviewingController`. Quick Look extension only.

[`config/`](config) holds the three `Info-*.plist` files for the app and extension targets, four `*.entitlements` files (release + debug pairs for the apps and the extension), and `Base.xcconfig` / `version.xcconfig` / a gitignored per-developer `Local.xcconfig`.

## License

MIT.

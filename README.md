# md.too

A minimalist Markdown viewer for macOS and iOS. Read-only, native, zero third-party dependencies.

## What it does

- Open a `.md` file and see it rendered.
- Select text, copy it, scroll. Code blocks and tables have a one-click copy button.
- macOS Quick Look extension renders `.md` in Finder's preview pane and on spacebar peek.
- Syntax highlighting for about 40 languages (Swift, C/C++/C#/Objective-C, Java, Kotlin, Scala, JS/TS, Python, Rust, Go, Ruby, PHP, Dart, Lua, Perl, R, Julia, Haskell, OCaml, F#, Elixir, Clojure, Groovy, SQL, GraphQL, Dockerfile, Makefile, TOML, INI, YAML, JSON, XML, HTML, CSS, Bash, PowerShell, Markdown).
- GitHub-style task lists (`- [ ]` / `- [x]`).
- Tiny LaTeX subset in `$…$` / `$$…$$`: Greek letters, super/subscripts, common operators, simple fractions.
- Export the rendered document to PDF (paginated, with images embedded).

See [EXAMPLE.md](EXAMPLE.md) for a single document that exercises every supported feature.

## What it doesn't do

No editor, no live edit/preview split, no autosave. No HTML or `WKWebView`. No file tree, tabs, or command palette. No app-level themes (light/dark follows the system, or pick one explicitly). No third-party packages — pure Swift + AppKit/UIKit/SwiftUI.

For context: the most popular JavaScript Markdown library, `marked`, reports about 636 transitive dependencies and roughly 38,980 lines of code on its public dependency graph. The md.too app is a few Swift files with no dependencies. Every package you do not pull in is a supply-chain risk you do not inherit.

## Why

A friend asked me last week what a Markdown file is. I had to explain that `.md` is the substrate the work is written on — README, AGENTS, PRD, every issue, every PR — and that I'd just spent a week cycling through half a dozen Electron viewers, each half a gigabyte of TypeScript shipping its own "Pro" upsell modal, and each still failing at a nested list inside a blockquote inside a code fence. So I lifted the Markdown renderer from [an earlier chat-app project](https://im-ai.local-llama.workers.dev/) of mine and made it a real app. The macOS build also exports to a paginated PDF on one click, and the Quick Look extension renders any `.md` in Finder's preview pane and on spacebar peek. The iOS build exists because once the parser and view were portable, it was three Info.plist keys away.

## Download

Signed and notarized macOS `.dmg` is published as a GitHub Release on each tagged version:

[**Latest release**](https://github.com/leok7v/md.too/releases/latest)

iOS app is in App Store review.

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

- [`MarkdownParser.swift`](src/MarkdownParser.swift) — `MarkdownDocument` (FileDocument), block parser, tiny LaTeX subset.
- [`MarkdownView.swift`](src/MarkdownView.swift) — top-level SwiftUI view.
- [`BlockViews.swift`](src/BlockViews.swift) — per-block render (heading, list, code, table, image).
- [`SelectableText.swift`](src/SelectableText.swift) — selectable / copyable text wrapper around `NSTextView` / `UITextView`.
- [`Highlight.swift`](src/Highlight.swift) — regex syntax highlighter, driven by [`highlights.ini`](src/highlights.ini).
- [`Platform.swift`](src/Platform.swift), [`FontRole.swift`](src/FontRole.swift), [`Environment.swift`](src/Environment.swift) — typealiases, font + theme support.

Apps only — macOS + iOS, not the Quick Look extension:

- [`App.swift`](src/App.swift) — `@main`, `DocumentGroup`.
- [`AppShell.swift`](src/AppShell.swift) — on-disk file-change watcher, window-frame autosave, system-theme bridge.
- [`Toolbar.swift`](src/Toolbar.swift) — share button.
- [`PDFRenderer.swift`](src/PDFRenderer.swift) — paginated PDF export with embedded images.

Per platform / per target:

- [`Bridges-macOS.swift`](src/Bridges-macOS.swift) — `NSViewRepresentable` for selectable text. macOS app + Quick Look extension.
- [`Bridges-iOS.swift`](src/Bridges-iOS.swift) — `UIViewRepresentable` for selectable text. iOS app only.
- [`Toolbar-macOS.swift`](src/Toolbar-macOS.swift) — Save-as-PDF panel. macOS app only.
- [`QuickLook.swift`](src/QuickLook.swift) — `QLPreviewingController`. Quick Look extension only.

[`config/`](config) holds the three `Info-*.plist` files for the app and extension targets, four `*.entitlements` files (release + debug pairs for the apps and the extension), and `Base.xcconfig` / `version.xcconfig` / a gitignored per-developer `Local.xcconfig`.

## License

MIT.

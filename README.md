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

## Layout

Four Swift files:

- [`Markdown.swift`](Markdown.swift) — parser, SwiftUI views, themes, native text.
- [`Highlight.swift`](Highlight.swift) — syntax highlighter.
- [`PDFRenderer.swift`](PDFRenderer.swift) — paginated PDF export with embedded images. macOS + iOS app targets only.
- [`QuickLook.swift`](QuickLook.swift) — Quick Look extension principal class. macOS Quick Look target only.

Three `Info-*.plist` files cover document-type and Quick Look extension configuration that flat build settings can't express; entitlements files describe the sandbox for each target. `Base.xcconfig` includes a committed `version.xcconfig` and an optional gitignored `Local.xcconfig`.

## Privacy

[Privacy policy](https://leok7v.github.io/md.too/privacy.html) — short version: the app collects nothing, stores nothing, transmits nothing. The only network requests are HTTPS image fetches for inline images you reference by URL in your own Markdown.

## License

MIT.

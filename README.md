# Markdown Too

A minimalist Markdown viewer for macOS and iOS. Read-only, zero third-party dependencies. The displayed app name is **Markdown Too**; the build product and Xcode project both use `md.too`. The bundle identifier is `com.leok7v.Markdown.Preview` (the project's original name, kept for continuity).

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

No editor, no live edit/preview split, no autosave. No HTML or `WKWebView`. No file tree, tabs, or command palette. No app-level themes (light/dark follows the system). No third-party packages — pure Swift + AppKit/UIKit/SwiftUI.

For context: the most popular JavaScript Markdown library, `marked`, reports about 636 transitive dependencies and roughly 38,980 lines of code on its public dependency graph. This project ships zero dependencies and the parser fits in one file. Every package you do not pull in is a supply-chain risk you do not inherit.

## Build

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

### Signing

The project ships with no `DEVELOPMENT_TEAM` set, so a fresh clone builds with ad-hoc ("Sign to Run Locally") signing — no Apple Developer account required for local development. To override locally, drop a one-line `Local.xcconfig` next to `Base.xcconfig` containing `LOCAL_DEVELOPMENT_TEAM = YOURTEAMID`; it's gitignored. To run on a physical iOS device or to distribute, open the target in Xcode → Signing & Capabilities and select your team.

## Distribution

`.github/workflows/dmg.yml` builds an unsigned `.dmg` on every push to `main` and a signed + notarized `.dmg` on tag push (`v*`). The signed `.dmg` is uploaded as a GitHub Release asset; the unsigned `.dmg` is a workflow artifact. To run an unsigned build, either right-click → **Open** the first time, or remove the quarantine attribute:

```sh
xattr -d com.apple.quarantine "/Applications/md.too.app"
```

The displayed app name is still **Markdown Too** in Finder, the Dock, and Cmd-Tab — only the bundle filename uses `md.too`.

## Layout

The whole app is two Swift files: [`MarkdownPreview.swift`](MarkdownPreview.swift) (parser, views, PDF export, Quick Look principal class) and [`Highlight.swift`](Highlight.swift) (syntax highlighter). Three Info.plist files cover document-type and Quick Look extension configuration that flat build settings can't express; entitlements files describe the sandbox for each target.

## License

MIT.

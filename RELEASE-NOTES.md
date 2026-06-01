# md.too - Release Notes

## Build 260601.0657 - 2026-06-01

A polish build. Tables in the app's continuous-selection view now render the same way they do in Finder Quick Look and in the block-tree fallback: column widths follow content proportion, long cells wrap inside their column instead of truncating at a tab stop. PDF export inherits the same column-width rules.

### Fixed

- **Long table cells wrap to multiple lines** in the main rendered view instead of being truncated with an ellipsis. Documents like benchmark write-ups, scoring rubrics, or anything with one short Question column and one long Answer column finally render the answer in full. Behind the scenes, the renderer moved from `NSParagraphStyle` tab stops to `NSTextTable` / `NSTextTableBlock` - the proper Cocoa text-table API. Cells wrap natively, zebra-stripe tints paint as cell-box fills, and the table reflows when the window resizes.

- **Column widths now distribute by content proportion** instead of defaulting to equal thirds at narrow window widths. A table whose Response column has paragraphs of text and Rating column has just a number gets a wide Response and a narrow Rating, the way you'd expect.

- **PDF table header text no longer breaks mid-letter.** A one-word header like "Rating" used to split into "R / a / ti / n / g" stacked vertically when the column allocation was narrow. The PDF renderer now measures each column's longest single word in the bold body font via Core Text, and the column-width metric reserves at least that much before distributing the remainder by content proportion. Headers fit on one line; long answer columns still get the lion's share.

- **The Table view-width-aware layout limit was lifted.** Previously documented as "deferred indefinitely" because the obvious implementation (rebuild the whole document string on every window resize) would have wiped selection and flickered. The actual fix used attribute-only mutation - and now `NSTextTable` handles it natively without our own resize loop.

### What stayed the same on purpose

The renderer's output for documents that already rendered correctly, the syntax highlighter's colors, the read-only nature of the app, continuous selection across paragraphs / headings / lists / quotes, atomic-block snap on code blocks / tables / images, and zero third-party dependencies.

### What to test

- A document with a table where one column has long multi-sentence cells - confirm those cells now wrap to multiple lines inside the column rather than truncating with `...`.
- A document with a table whose header is a single word (e.g. "Rating"). Save it to PDF - the header should fit on one line in the PDF, not break per character.
- Resize an app window over a document with a table; column proportions should hold as the window narrows or widens.
- Tables in code fences (triple-backtick blocks) still render as code (literal pipes preserved, monospace font). That is correct - code fences are explicit.

### Known rough edges

- The atomic-block snap arbiter for continuous selection still runs on macOS only; iOS uses the simpler per-block selection model.
- The first `.md` file with many remote images may take a moment to fully paint while inline fetches complete.
- Display math `$$E = mc^2$$` uses a small LaTeX subset. Full LaTeX is intentionally out of scope.

### Where to send feedback

GitHub Issues: https://github.com/leok7v/md.too/issues
GitHub Discussions: https://github.com/leok7v/md.too/discussions

Or the TestFlight feedback button. Screenshots help; attaching the source `.md` file helps more.

Thank you for testing.

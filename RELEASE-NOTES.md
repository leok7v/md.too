# md.too - Release Notes

## Build 260601.0657 - 2026-06-01

The render fix release: tables stop misbehaving on documents that have one short column and one paragraph-length column. If you've been looking at a benchmark, a scoring rubric, a Q&A log, or anything where a column's content is long-form text, this is the one that makes those documents read right.

### Three things now work the way you'd expect

- **Long table cells wrap inside their column.** Previously, a cell whose content spilled past the column's allocated width was truncated at the column boundary with an ellipsis (`...`). Now the cell flows to multiple lines inside its column, the way it does in any modern HTML table renderer. The big difference: open something like a model-evaluation log where the Response column has full paragraphs of answer text - you'll see the answer in full.

- **Column widths reflect what's in each column.** A 3-column table with a Question column, a paragraph-long Response column, and a 4-character Rating column gets a wide Response, a medium Question, and a narrow Rating - even when the window is narrow. Previously narrow windows degraded to roughly-equal columns regardless of content.

- **PDF table headers don't break mid-letter anymore.** When you `Save as PDF` a table whose narrowest column has just a short header word ("Rating", "Score", "%", etc.), that header used to stack as `R` / `a` / `t` / `i` / `n` / `g` vertically because the column allocation undercut the bold header word's width. The PDF renderer now measures each column's longest single word and reserves at least that much width before distributing the remainder by content proportion.

### What stayed the same on purpose

The renderer's output for documents that already rendered correctly, the syntax highlighter's colors, the read-only nature of the app (md.too never writes to your `.md` files), continuous selection that flows across paragraphs / headings / lists / quotes, atomic-block snap when a drag crosses a code block / table / image, and zero third-party dependencies.

### Under the hood (skip unless you're curious)

Tables in the in-app rendered view moved from `NSParagraphStyle` tab-stop paragraphs to `NSTextTable` + `NSTextTableBlock` - the proper Cocoa text-table API. The tab-stop model was inherited from an earlier table design that assumed cells would always be short; it had no way to wrap content within a column. `NSTextTable` does, plus Cocoa's `fixedLayoutAlgorithm` reflows the whole table when the window resizes. Per-column widths come from a sqrt-weighted content metric that's shared with the PDF renderer, so the proportions agree between on-screen, Quick Look, and exported PDF.

### What to test

- Open a `.md` file with a 3+ column table where one column has long paragraphs - confirm the long column wraps inside its column rather than truncating with `...`.
- Drag the window narrower and wider over the same document - column proportions should hold, not collapse to equal widths.
- `Save as PDF` from the toolbar. Open the PDF. A short-header column should show its header on one line, not split per character.
- Tables in code fences (triple-backtick) still render as code, with literal pipes preserved in monospace. That's the correct behavior - code fences are explicit.

### Known rough edges

- The atomic-block snap arbiter for continuous selection runs on macOS only; iOS uses the simpler per-block selection model.
- The first `.md` file with many remote images may take a moment to paint while inline fetches complete.
- Display math (`$$E = mc^2$$`) uses a small LaTeX subset. Full LaTeX is intentionally out of scope.

### Where to send feedback

GitHub Issues: https://github.com/leok7v/md.too/issues
GitHub Discussions: https://github.com/leok7v/md.too/discussions

Or the TestFlight feedback button. Screenshots help; attaching the source `.md` file helps more.

Thank you for testing.

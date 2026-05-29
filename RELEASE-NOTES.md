# md.too - Release Notes

## Build 260529.0251 - 2026-05-29

A feature build. Selection now flows continuously across the document the way the document reads, Copy attaches every paste flavor a target might want, you can save to HTML in addition to PDF, and tables learned to zebra-stripe on screen and to honor formatting inside cells.

### New

- **Continuous selection across the whole document.** Drag from one paragraph through a heading into a list and on into a quote - the selection flows the way the document reads, with no jumps at block boundaries. Cmd-A selects the whole document end-to-end and copies clean text. Code blocks, tables, and images are atomic: clicking inside one still lets you select within it, but a drag that started outside snaps that whole block as a unit when the cursor leaves it, so a quick highlight never ends mid-table.

- **Copy with every paste flavor at once.** The toolbar Copy button (and Cmd-C) puts plain text, HTML, RTF, and a fully laid-out PDF on the clipboard in one click. The destination app picks the best format on paste:
  - Terminal, a code editor, or an `<input>` field gets readable Markdown-flavored text. Tables come through as width-aligned ASCII so columns line up.
  - Mail, Gmail, Notes, and any rich-text editor get formatted HTML with bold / italic / code / links / tables / zebra striping preserved.
  - TextEdit and other Cocoa rich-text targets get RTF.
  - Pages, Keynote, or Preview get the PDF.

  The PDF flavor renders only the first time a destination asks for it, so Copy itself stays instant; on the keyboard, Cmd-C and a paste into Mail behave the same as Copy in any rich-text app.

- **Save as HTML.** A second save button to the right of "Save as PDF" writes a single self-contained `.html` file with all images embedded as base64 and styles attached inline on every element. Theme-neutral grays, no JavaScript, no external CSS, no `<style>` block. It opens and prints anywhere, survives Gmail's sanitizer untouched, and round-trips cleanly through TextEdit's HTML-to-RTF converter.

- **On-screen tables get zebra striping and a header band.** Alternating rows pick up a subtle tint and the header row carries a slightly stronger one, so a wide table is easier to scan even when it scrolls horizontally. The shading is theme-neutral - looks right in light and in dark mode without re-tinting.

- **Inline formatting inside table cells.** Bold (`**bold**`), italic (`*italic*`), inline code (`` `code` ``), strikethrough (`~~strike~~`), and links (`[label](url)`) inside a cell render the way they do in a paragraph - both on screen and in the exported PDF. A cell that used to show four literal asterisks now shows bold text.

- **Multi-block list items keep their indent.** A bullet whose body continues with a follow-up paragraph or a fenced code block now keeps the continuation aligned under the bullet body, so the second block reads as part of the item rather than escaping back to the left margin.

### Fixed

- **PDF tables now use the same column widths as on screen** and the header row carries the matching shaded band, so the PDF and the in-app rendering finally agree on table layout.

- **The PDF table header band is opaque again.** A regression introduced when adding row shading silently lost the header tint on dark documents; the band now fills correctly under the header text.

- **Bold inside PDF table cells renders bold,** not as the literal `**` markers. The fix walks each cell's inline runs and bakes bold / italic / monospace traits into explicit fonts that Core Text honors during PDF layout.

### Also

- **Copy gives visible feedback.** The Copy button briefly swaps to a checkmark and shows a small "Copied" capsule beneath itself, so it's obvious the click registered. The Save-as-PDF and Save-as-HTML buttons carry tiny "pdf" / "html" badges in the corner so the two are distinguishable at toolbar size.

- **Quick Look extension still shows just Source and Theme** in its top-right cluster; copying, saving, and sharing all happen in the full app.

### What stayed the same on purpose

The renderer's output for documents that already rendered correctly, the syntax highlighter's colors, the read-only nature of the app (md.too never writes to your `.md` files; the new exports go through Save panels or the clipboard, never back to the source), and zero third-party dependencies.

### What to test

- Drag a selection across several paragraphs, then through a code block, then through a table - confirm the selection flows continuously and that the code block and table snap whole when the cursor leaves them. Cmd-A then Cmd-C, then paste into a text editor - the whole document should come through.
- Copy the document, then paste it into Terminal, Mail, TextEdit, and Pages - each should take the format it understands best.
- Save a document as HTML, open the `.html` in a browser, and confirm tables, code blocks, and images render. Paste the same HTML into Gmail and confirm the formatting survives sanitization.
- A table cell containing `**bold**`, `*italic*`, `` `code` ``, and `[link](url)` - confirm each renders correctly on screen and in the exported PDF.
- A bulleted list with a second paragraph or fenced code block under a single bullet - confirm the continuation stays under the bullet body, not at the left margin.
- Anything that renders visibly worse here than on github.com for the same source.

### Known rough edges

- The atomic-block snap arbiter for continuous selection currently runs on macOS only; iOS uses the simpler per-block selection model.
- The first `.md` file with many remote images may take a moment to fully paint while inline fetches complete.
- Very wide tables may scroll horizontally; the layout is correct but visually busy.
- A table cell whose inline-formatted content exceeds its column width truncates with an ellipsis - tab-stop tables do not wrap within a column.
- Display math `$$E = mc^2$$` uses a small LaTeX subset. Full LaTeX is intentionally out of scope; complex equations may not render the way a TeX engine would.

### Where to send feedback

GitHub Issues: https://github.com/leok7v/md.too/issues
GitHub Discussions: https://github.com/leok7v/md.too/discussions

Or the TestFlight feedback button. Screenshots help; attaching the source `.md` file helps more.

Thank you for testing.

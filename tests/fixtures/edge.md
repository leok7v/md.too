# Edge cases

The shapes the feature tour does not reach, one per section, so the
parser and the exporters are pinned on them too.

## Task items with children

- [x] A done task with a follow-up paragraph

  The paragraph belongs to the task.

  - [ ] a nested task under it
  - [ ] and a second one
- [ ] An open task with a quote

  > quoted under the task

## Loose ordered list past nine

8. eight
9. nine
10. ten, with a code block under it

    ```sh
    echo ten
    ```

11. eleven

## Code spans with backticks

A span holding a backtick: `` a`b ``. One that starts with one: ``` `x ```.
A backslash pair inside code stays literal: `\\` and `\n`.

## Hard breaks and escapes

First line  
second line after a hard break, then an escaped \*star\* and a literal
underscore_in_a_word.

## Empty and odd cells

| a | b |
|---|---|
|   | only b |
| only a |

## Aligned columns and escaped pipes

| Left | Centre | Right | Pipe |
|:-----|:------:|------:|------|
| a | b | c | x \| y |
| aa | bb | cc | `p\|q` |

## A tolerant delimiter row

| Metric | Value |
|---|:**|
| cells | still a table |

## Code spans are opaque

A definition exists for [cmark] below, and `[cmark]` in code is not a link.
Prices in code: `$5 and $6` stay dollars, and `<sup>2</sup>` in code keeps
its tags, while <sup>2</sup> outside is a superscript.

[cmark]: https://commonmark.org

## Tabs after markers

-	tab after a bullet
>	tab after a quote marker

## Indented continuation

first line
    second line, indented four, still the same paragraph

    a real indented code block after a blank line

## Task boxes at the end of the line

- [ ]
- [x]
- [ ] with text

## Code blocks keep their HTML

    <b>indented</b> code keeps <br> and <!-- this -->

```html
<p align="center"><img src="x.png"></p>
```

$$
a <b> b
$$

## A comment between paragraphs

first paragraph
<!-- a comment
over two lines -->
second paragraph

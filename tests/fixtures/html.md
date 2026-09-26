# HTML the models write

Fragments that arrive inside markdown from models and README authors,
handled by the allow-list and nothing else.

## Line breaks and small print

First line<br>second line<br/>third line<br />fourth line.

Some text with <small>small print</small> after it.

A cell with a break:

| Item | Note |
|---|---|
| one | first line<br>second line |

## Synonyms for markdown

Bold <b>b</b> and <strong>strong</strong>, italic <i>i</i> and <em>em</em>,
struck <s>s</s>, <del>del</del> and <strike>strike</strike>, code <code>x</code>
and a key <kbd>Cmd</kbd>.

## Links and images

A link <a href="https://example.com/a">to a</a> and one with
<a href='https://example.com/b' target="_blank">single quotes</a>.

<img src="https://example.com/logo.png" alt="Logo" width="128" height="64">

Inline in a cell:

| Logo | Site |
|---|---|
| <img src="https://example.com/i.png" width="32"> | <a href="https://example.com">home</a> |

## Comments are dropped

Before <!-- an inline comment --> after.

<!-- a block comment
that spans lines -->

Still here.

## Centred wrappers

<div align="center">
  <b>A centred title</b>

  A centred paragraph under it.
</div>

<p align="center">One line, opened and closed together.</p>

## Details

<details>
<summary>Click to expand</summary>

Hidden text, shown open here.

- with a list
</details>

## Entities and unknown tags

An &nbsp; entity, an &amp; ampersand, &copy; and a dash &#8212; decode;
`&nbsp;` in code stays literal, and an <unknown attr="x">unknown tag</unknown>
stays as written. So does <br> inside `<br>` code.

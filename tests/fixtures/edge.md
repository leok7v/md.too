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

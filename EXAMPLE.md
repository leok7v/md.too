# Less Is More

A short essay about plain text that looks good, plus a regression test for every feature this app renders.

## How we got here

In 2004 John Gruber wrote down a tiny set of rules so people writing on the web could stop copying HTML angle brackets around like they were eggs. The rules fit on one page. The promise was simple: write the way you would write in a notebook, save the file as plain text, and let some small program turn it into something pleasant to read. **Less syntax, more reading.** *Asterisks for emphasis. Hashes for headings. A blank line for a new paragraph.* That was the whole pitch.

Two decades later the average Markdown editor ships with roughly the same disk footprint as a small mainframe. There is a kind of poetry in opening a 240MB application to read four paragraphs about your weekly groceries. We do not judge. We just keep a smaller tool nearby for when we want to read.

> "Programs are meant to be read by humans and only incidentally for computers to execute."  Hal Abelson, *Structure and Interpretation of Computer Programs*. Markdown asks for the same courtesy from your text.

## Math, the small kind

A guided tour of the LaTeX subset, with no pretense of being a full TeX engine.

Inline: $\alpha + \beta = \gamma$, the right triangle staple $x^2 + y^2 = z^2$, Gauss's schoolboy trick $\sum_{i=1}^{n} i = \frac{n(n+1)}{2}$ (he was nine, allegedly), and $x \in \mathbb{R}$. Display blocks get a little more room:

$$E = mc^2$$

Greek alphabet, lower and upper, in case you need both at once:

$$\alpha \beta \gamma \delta \epsilon \zeta \eta \theta \iota \kappa \lambda \mu \nu \xi \pi \rho \sigma \tau \phi \chi \psi \omega$$

$$\Gamma \Delta \Theta \Lambda \Xi \Pi \Sigma \Phi \Psi \Omega$$

Operators and a corner of set theory: $\le \ge \neq \approx \pm \times \cdot \div \to \Rightarrow$, $\forall x \in \mathbb{N}, \exists y \in \mathbb{Z}$, $A \cap B$, $A \cup B$, $\varnothing$.

Past this (matrices, integrals with bounds, multi line equations) we punt to verbatim source. We are not above admitting our limits. If you need real LaTeX, render the document to PDF in a tool that ships with a real TeX install and paste the equation as an image.

## Footprints

A few napkin numbers for context. Sizes are rough installer or app bundle measurements on macOS and they drift; spirit holds.

| Tool                  | Approximate size | What it edits           |
| :---                  |             ---: | :---                    |
| `vi`                  |             1 MB | anything plain          |
| `nano`                |             2 MB | anything plain          |
| this app              |             4 MB | rendered Markdown       |
| Visual Studio Code    |           370 MB | code, prose, your hopes |
| Obsidian              |           250 MB | notes, plus a graph     |
| Typora                |           120 MB | Markdown only           |

## What we shipped, and what we are still chewing on

* [x] write a parser that fits in a tiny Swift codebase,
* [x] make the Quick Look extension feel like the rest of the app,
* [x] externalize syntax data so adding a language is one line,
* [x] keep the source under 2,500 lines,
* [x] decide whether tables should support inline images (yes, image only cells).

## Code that travels well

Each fence below should color the way you expect. If a block looks plain, the language tag is probably misspelled or the language is one we have not added yet.

Swift:

```swift
import Foundation

struct Greeter {
    let name: String
    func greet() -> String {
        return "Hello, \(name)!"
    }
}

let g = Greeter(name: "World")
print(g.greet())
```

C, with a preprocessor line and a block comment:

```c
#include <stdio.h>

/* Block comment.
   Should color through line breaks. */
int main(int argc, char** argv) {
    const char* msg = "hello, world\n";
    for (int i = 0; i < argc; ++i) {
        printf("%s argv[%d] = %s\n", msg, i, argv[i]);
    }
    return 0;
}
```

C++:

```cpp
#include <vector>
#include <string>

template <typename T>
auto sum(const std::vector<T>& xs) -> T {
    T total{};
    for (const auto& x : xs) total += x;
    return total;
}
```

Java:

```java
import java.util.List;

public class Greeter {
    private final String name;
    public Greeter(String name) { this.name = name; }
    public String greet() { return "Hello, " + name + "!"; }

    public static void main(String[] args) {
        var g = new Greeter("World");
        System.out.println(g.greet());
    }
}
```

Kotlin:

```kotlin
data class User(val id: Int, val name: String)

fun greet(u: User): String = "Hello, ${u.name} (${u.id})"

fun main() {
    val u = User(id = 1, name = "World")
    println(greet(u))
}
```

JavaScript:

```javascript
const greet = (name) => `Hello, ${name}!`;
async function main() {
    const res = await fetch("https://api.example.com/users");
    const json = await res.json();
    console.log(json);
}
```

TypeScript:

```typescript
interface User { id: number; name: string; }
function greet(u: User): string {
    return `Hello, ${u.name} (${u.id})`;
}
```

Python, with a decorator and a triple quoted docstring:

```python
from dataclasses import dataclass

@dataclass
class User:
    id: int
    name: str

def greet(u: User) -> str:
    """Triple quoted docstring should highlight as a string."""
    return f"Hello, {u.name} ({u.id})"
```

Rust, with attributes:

```rust
#![allow(dead_code)]

fn greet(name: &str) -> String {
    format!("Hello, {}!", name)
}

fn main() {
    let v: Vec<i32> = (1..=5).collect();
    println!("{:?}", v);
}
```

Go:

```go
package main

import "fmt"

func main() {
    nums := []int{1, 2, 3}
    for i, n := range nums {
        fmt.Printf("%d: %d\n", i, n)
    }
}
```

Ruby:

```ruby
class Greeter
  attr_reader :name
  def initialize(name) = @name = name
  def greet = "Hello, #{name}!"
end

puts Greeter.new("World").greet
```

JSON, with the keys colored as attributes and the values colored by type:

```json
{
    "name": "Markdown Preview",
    "version": "1.0",
    "features": ["headings", "lists", "tables", "code", "math"],
    "deps": null
}
```

YAML, with keys, list bullets, and the `~` keyword each in their own color:

```yaml
name: Markdown Preview
features:
  * headings
  * tables
  * syntax_highlighting
deps: ~
```

TOML, where section headers and assignments get their own colors:

```toml
[package]
name = "markdown_preview"
version = "1.0.0"

[features]
math = true
images = false
```

SQL, mixing case to confirm both are recognized:

```sql
SELECT name, count(*) AS n
FROM events
WHERE created_at > '2026_01_01'
GROUP BY name
ORDER BY n DESC
LIMIT 10;
```

Bash, with a shebang, a comment, and a `$variable`:

```bash
#!/usr/bin/env bash
set -euo pipefail
for f in *.md; do
    wc -l "$f"
done
```

Dockerfile:

```dockerfile
FROM alpine:3.19
RUN apk add --no-cache curl
WORKDIR /app
COPY . /app
ENTRYPOINT ["./run.sh"]
```

HTML:

```html
<!DOCTYPE html>
<html>
  <head><title>Hello</title></head>
  <body><h1 class="greeting">Hi</h1></body>
</html>
```

CSS:

```css
.body {
    font_family: _apple_system, BlinkMacSystemFont, sans_serif;
    padding: 1.5rem 2rem;
    color: #2a1500;
}
```

A code fence with no language stays plain monospaced, which is what you want for shell transcripts and ASCII art:

```
no language => no highlighting, just the monospace font
the [copy] button still works
```

An indented code block (four spaces) renders the same way:

    int x = 0;
    for (int i = 0; i < 10; ++i) x += i;

***

## A quick combined block

Just to confirm everything composes:

> A blockquote with a [link](https://example.com), some `inline code`, and even a math fragment $\pi \approx 3.14159$ on one line.

1. List item with **bold**, then a code span: `let x = 42`.
2. List item with a [link](https://swift.org).
3. `code only item`

| Description             | Example                       |
| ---                     | ---                           |
| Code in a cell          | `let x = 1`                   |
| Link in a cell          | [click](https://example.com)  |
| Bold and italic in cell | ***strong***                  |
| Empty cell              |                               |

Hard line breaks still work. The next sentence ends with two trailing spaces  
so this part starts on its own line, no paragraph gap, no fuss.

You can also <u>underline through raw HTML</u> and ~~strike things out~~ when the situation calls for it. We try not to call for it.

## A picture is worth a few hundred bytes

Block level images load from any URL the document points at. If the load fails, we render a captioned placeholder so the layout never collapses around a missing image. A trailing `{width=NNN}` (GitLab style) caps the rendered width; `{height=NNN}` does the obvious thing.

Images can also live inside table cells, one image per cell. Setting the same `height` on both lines them up at the same vertical extent even though one is portrait and the other landscape:

| Renaissance      | Apollo           |
| :---:            | :---:            |
| ![Mona Lisa](https://dn710208.ca.archive.org/0/items/mona-lisa-by-leonardo-da-vinci-from-c-2-rmf-retouched/Mona_Lisa%2C_by_Leonardo_da_Vinci%2C_from_C2RMF_retouched.jpg){height=200} | ![Earthrise](https://archive.org/download/297755main_GPN-2001-000009_full/297755main_GPN-2001-000009_full.jpg){height=200} |
| Internet Archive | NASA             |

The next image points to a deliberately broken URL so you can see the captioned-placeholder fallback. Layout doesn't collapse around the missing content; the alt text becomes a small box with a photo icon and the caption right where the image would have gone:

![image not found](https://example.com/some-image.png)

***

## Memory and performance

A Markdown file is just bytes. The most this reader needs to hold in memory is roughly the file size, $M \le c \cdot N$. A typical 40 KB README weighs about 50 KB once parsed, and renders in under one frame.

A popular Electron-based editor uses ~240 MB on disk and ~400 MB of memory per window for the same job:

$$\frac{M_\text{electron}}{M_\text{this}} \approx 100$$

A 100× memory premium for HTML rendering of plain Markdown is a choice. Reasonable people make it. We chose differently.

### The supply-chain axis

The most popular JavaScript Markdown library, `marked`, lists about 636 transitive packages and ~39,000 lines of code on its public dependency graph. Doing the same job in a tiny Swift codebase with zero dependencies turned out to work.

Pick a rough industry defect rate of $\delta \approx 15$ bugs per 1,000 lines. The "code a user runs" is the app plus every dep:

| Stack                          | Lines    | Expected defects |
|:-------------------------------|---------:|-----------------:|
| TypeScript with `marked`       | ~3.2 M   | ~48,000          |
| This app, zero dependencies    | ~2,000   | ~30              |

Now the CVE side. If each dependency has a 1-in-200 chance of harboring a fresh CVE in a year, the odds *at least one* dep in a tree of $N$ does is

$$P = 1 - (1 - 0.005)^N$$

For 636 deps that is ~96%. For 0 deps it is 0%. Every package you don't pull in is a CVE you don't have to read on a Saturday night.

This is napkin math, not a peer-reviewed study. The point is the multiplier sitting in front of every other consideration.

### Time you actually spend

Adults read prose at about 250 words per minute. A 10,000-word document is ~40 minutes of reading. Any feature that adds a few seconds to startup quietly steals from those 40 minutes before the reader has seen a single word.

Optimizing for the small things is just respect.

***

## Closing thought

Good prose is short. Good code is short. Good tools are smaller than you think they need to be.

If you scrolled this far without your CPU pinning, the layout loop is holding. The Share button in the toolbar exports this entire document, code blocks and tables and image captions and all, to a paginated PDF.

That, in the end, is the point.

***

Copyright (c) 2026 Dmitry "__Leo__" Kuznetsov

# Clipboard Saver

A macOS app that turns the clipboard into a file, from the Finder context menu.

Right-click anywhere in a Finder window, pick **Save Clipboard as Markdown
Here**, and the clipboard is written to that folder as Markdown. The filename is
offered in a save panel, pre-filled from the document's own heading, and you can
edit it before saving.

There is no window, no menu bar and no Dock icon. The app exists only to serve
the Services menu, which is why it is an `LSUIElement` agent that terminates
after each save.

---

## Requirements

| | |
|---|---|
| macOS | 15.5 or later |
| Xcode | 16 or later (developed against 26.6) |
| Swift | 5 language mode |
| Architecture | arm64, x86_64 |

## Install

```sh
git clone https://github.com/nyimbi/clip_saver.git
cd clip_saver/Clipboard_saver          # the Xcode project lives one level down
xcodebuild -project Clipboard_saver.xcodeproj \
           -scheme Clipboard_saver \
           -configuration Release \
           -destination 'platform=macOS' build
cp -R <path>/Build/Products/Release/Clipboard_saver.app /Applications/
open /Applications/Clipboard_saver.app   # once, so it registers itself
```

The first launch registers the app as a login item. **This step matters** — see
[Why it silently did nothing](#why-it-silently-did-nothing).

## Use

The Finder context menu is the supported way to use this app. All three of
these are verified working:

| Where you click | Menu item | Destination |
|---|---|---|
| Background of a Finder window | Save Clipboard as Markdown Here | The folder shown in that window |
| A folder, or several | Save Clipboard as Markdown | Inside each selected folder |
| A file | Save Clipboard as Markdown | Alongside the file |

A fourth service, **Save Clipboard to File** (saves to the Desktop), is declared
and its code path is correct, but **a stock macOS never offers it** — see
[Known limitations](#known-limitations).

The two Finder items are not duplicates. A background right-click puts no file
URL on the pasteboard, so the folder service is not offered there at all; the
"Here" service is the only one available in that case.

Writing never overwrites an existing file. A colliding name gets a ` (n)`
suffix, and the first directory you see keeps the name you confirmed in the
panel even if that means replacing a file — subsequent directories are
collision-resolved so a multi-folder save can never silently destroy a second
file.

## How the clipboard is interpreted

The app takes the richest representation available on the pasteboard:

1. **Plain text that is already Markdown** wins outright, even when HTML is also
   present. "Copy" from a Markdown-aware source — ChatGPT, a code editor, a
   terminal — puts both on the clipboard, and re-deriving structure from that
   HTML would only add risk.
2. **HTML** is parsed structurally and converted (see below).
3. **RTF** is converted by inspecting the style run.
4. **Plain text** is saved verbatim as `.txt`.

The extension follows: anything but a plain-text fallback becomes `.md`.

### HTML conversion

`HTMLToMarkdown.swift` is a single-pass tokenizer that walks the tag tree:
headings, paragraphs, ordered/unordered/nested lists, task-list checkboxes,
blockquotes, fenced code (with the language from `class="language-…"`), pipe
tables, links, images, and inline bold/italic/code/strikethrough. Inline
`style="font-weight:…"` is honoured too, because Safari emits styled spans
where other browsers emit semantic tags.

Output is escaped so that source text cannot accidentally become Markdown
structure — a literal `# heading` line comes out escaped as `\# heading`.

### RTF conversion

RTF has no tag tree, so structure comes from the style run. The rule that makes
this usable is that the *modal* font size is body text, and a heading must be
both larger than the body and bold. Tab-delimited lines become tables, and
bullets — which `NSAttributedString` pads with tabs — are found after the
leading whitespace.

## Architecture

```
Clipboard_saverApp.swift   NSServices entry points and the save pipeline
MarkdownExporter.swift    picks the richest pasteboard representation
HTMLToMarkdown.swift      HTML  → Markdown   (the bulk of the code)
RTFToMarkdown.swift       RTF   → Markdown   (fallback)
FilenameGenerator.swift   heading → safe, unique filename
```

All three services share one pipeline. The clipboard is read, converted, named,
and written atomically; the service then reports the outcome and terminates.
Filename resolution is split out into pure functions so it is testable without a
window.

`AppDelegate.save(into:)` and `save(export:into:name:)` return a `SaveOutcome`
rather than terminating the process, which is what makes the whole pipeline
testable in-process.

## Testing

```sh
./scripts/test.sh
```

**153 tests, 0 failures** (150 unit, 3 UI).

The wrapper is not decoration. The scheme is shared and committed at
`Clipboard_saver.xcodeproj/xcshareddata/xcschemes/Clipboard_saver.xcscheme`
with both test targets wired in. Without it Xcode auto-generates a scheme that
lists only the UI-test bundle, so `xcodebuild test` reports `** TEST SUCCEEDED **`
after running **4** tests — a green result that silently excludes 150. The script
reads the executed count out of the `.xcresult` and fails if it is zero or below a
floor, so a vacuous pass cannot be mistaken for a pass. `MIN_TESTS` overrides the
floor (default 150).

| Suite | Tests | Covers |
|---|--:|---|
| `HTMLToMarkdownTests` | 64 | Structure preservation, escaping, hostile input, throughput |
| `FilenameGeneratorTests` | 15 | Title extraction, sanitising, collisions |
| `SavePipelineTests` | 18 | Pasteboard → file on disk, destination resolution, failures |
| `ServiceContractTests` | 13 | `Info.plist` ↔ selector contract |
| `ChosenFilenameTests` | 17 | The name confirmed in the save panel |
| `RTFToMarkdownTests` | 13 | Style-based conversion |
| `MarkdownExporterTests` | 10 | Representation choice, Markdown detection |
| UI tests | 3 | Launch smoke test (Xcode template) |

`ServiceContractTests` deserves a note. macOS dispatches a service by looking up
its `NSMessage` string on the services-provider object, and enumerates the menu
from the bundle's `CFBundleIdentifier`. A missing identifier or a selector that
does not exist produces **no build error and no runtime error** — the menu item
simply never appears or does nothing. Every one of those links is asserted.

## Performance

Linear, single pass. Measured on the conversion path (best of three, release
build):

| Input | Time | Throughput |
|---|--:|--:|
| ChatGPT-style answer, 369 B | 0.1 ms | 4.5 MB/s |
| Medium document, 6 KB | 1.1 ms | 5.3 MB/s |
| Large document, 63 KB | 11.4 ms | 5.3 MB/s |
| Very large document, 643 KB | 119 ms | 5.1 MB/s |
| 2 MB with no tags | 374 ms | 6.1 MB/s |
| 500k entities, 2.5 MB | 215 ms | 11.1 MB/s |

Adversarial inputs stay linear too: 200k unclosed `<div>` tags parse in 20 ms,
100k unbalanced close tags in 18 ms, a 1000-column table row in 2.1 ms. A test
asserts that a 63 KB document converts in under 5 seconds — roughly two orders
of magnitude of headroom over the real 15 ms — which fails loudly if anything
super-linear is reintroduced.

## Robustness

The parser is exposed to whatever is on the pasteboard, including deliberately
hostile input. Two classes of bug were found and fixed by fuzzing it:

- **Stack overflow on deep nesting.** `Element` is a recursive value type, so
  50,000 unclosed `<div>` tags produced a 50,000-deep tree, and releasing that
  tree recursed 50,000 frames and killed the process with SIGSEGV. Nesting is
  now capped at 256 levels, which real markup never approaches; deeper content
  is flattened into the innermost element that was kept rather than dropped.
- **Silent content loss on a truncated pasteboard.** An unterminated attribute
  quote made the rest of the document an attribute value, losing the entire
  body. The parser now rewinds and salvages the text.
- **A save silently dropped when the typed name was all illegal characters.**
  Typing `///` into the save panel and pressing Save sanitised to nothing, which
  was reported as a cancellation — so nothing happened and nothing was said. It
  now falls back to the suggested name.
- **One malformed entry discarded an entire legacy pasteboard list.** The
  fallback read `NSFilenamesPboardType` with an `as? [String]` cast, so a single
  non-string element threw away every path. It now filters element by element.

## Why it silently did nothing

Five independent causes, none of which produced a build error. This is recorded
because each one is invisible in code review:

1. **The bundle had no identity.** `GENERATE_INFOPLIST_FILE` is `NO` and the
   hand-written plist declared neither `CFBundleIdentifier` nor
   `CFBundleExecutable`. LaunchServices cannot register or launch a Services app
   without an identifier, so the context menu never offered the service at all.
2. **A stale build shadowed the fix.** `/Applications` outranks
   `~/Applications` for service resolution, and the copy there was months old
   and equally broken.
3. **The tests did not compile**, so nothing had ever been verified — and over
   half of them asserted on a method with no call site.
4. **The converter destroyed the document.** It round-tripped HTML through
   `NSAttributedString` and re-derived structure from font metrics. That
   importer flattens the tag tree onto a handful of point sizes, so `<p>` was
   indistinguishable from `<h5>`, `<li>` arrived as `"\t•\tItem"`, and tables,
   links and blockquotes were lost entirely.
5. **The test command lied.** The scheme was never committed, so Xcode
   auto-generated one containing only the UI-test bundle. `xcodebuild test`
   exited 0 having run 4 of 153 tests and printed `** TEST SUCCEEDED **`. The
   suite could have been deleted and the build would still have reported green.
   The unit tests are also Debug-only: `ENABLE_TESTABILITY` is `NO` in Release,
   so the seven `@testable import Clipboard_saver` files fail to compile against
   a Release build.

## Known limitations

- **The app sandbox is disabled.** Writing to arbitrary folders and sending
  AppleEvents to Finder both require it, and there is no useful sandbox profile
  for a file-writing utility.
- **"Save Clipboard to File" is not offered on a stock macOS.** The service is
  declared and correct, but macOS only surfaces services from third-party apps
  in an application's Services menu if they appear in
  `/System/Library/CoreServices/com.apple.NSServicesRestrictions.plist`. That
  list is SIP-protected system state containing 58 allowlisted Apple bundles;
  `datacraft.Clipboard-saver` is not among them and cannot be added by the app.
  Confirmed empirically: the entry is absent from TextEdit's Services menu
  while allowlisted services (`Activity Monitor`, `File Activity`, …) are
  present, and it is absent from the Finder context menu too. It is kept
  because it costs nothing and works wherever the app is allowlisted, but it
  should not be relied on. The Finder context menu is the working path.
- **`saveToFolder` has not been isolated in a GUI run.** It is exercised by unit
  tests and appears in the real context menu, but the right-click-a-folder case
  was not driven end to end. The background (`saveHere`) path was.
- **Two generations of this tool are not in this repository.** A dead
  35-line Python prototype and a 450-line zsh Quick Action live one directory
  above the repo root. The Quick Action works but behaves differently — no HTML
  conversion, it appends to `.md` files, and it has no save panel.
- **The `NSFilenamesPboardType` fallback cannot be tested.** That pasteboard
  type cannot be synthesised, so the branch that reads it is defensive and
  unverified.

## Project layout

```
Clipboard_saver.xcodeproj      Xcode project (objectVersion 77, synchronized folders)
  xcshareddata/xcschemes/     Committed scheme — both test targets, Debug
Clipboard_saver/
  Clipboard_saverApp.swift     Services entry points, save pipeline
  MarkdownExporter.swift       Representation choice
  HTMLToMarkdown.swift         HTML → Markdown
  RTFToMarkdown.swift          RTF → Markdown
  FilenameGenerator.swift      Heading → safe unique filename
  Info.plist                   NSServices declarations, bundle identity
  Clipboard_saver.entitlements Sandbox off
  Assets.xcassets/
    AppIcon.appiconset         10 sizes, 1x and 2x, distinct per slot
Clipboard_saverTests/          150 unit tests
Clipboard_saverUITests/        Launch smoke test
scripts/test.sh                Runs the suite and fails on a vacuous pass
```

The project uses Xcode 16 synchronized folder groups, so a new `.swift` file
placed in `Clipboard_saver/` or `Clipboard_saverTests/` is picked up by the
build without editing `project.pbxproj`.

## Licence

Not specified. Add one before publishing.

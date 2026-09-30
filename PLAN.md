# Browser chat archiving — plan

The gap: AI chat UIs live in the browser, hold real work, and mostly cannot be
saved to a file. The clipboard service here already converts rich content to
Markdown well (64 structural tests). The missing piece is getting a whole
conversation out of a browser tab, and then making the saved pile usable months
later.

## Substrates

Three pieces with almost no code in common. Treating them as one backlog is how
this gets half-built.

| Substrate | Language | Distribution | Contains |
|---|---|---|---|
| **Core** (exists) | Swift | `/Applications` | HTMLToMarkdown, RTF, filenames, Services |
| **Bridge** (new) | Swift + JS | Chrome/Safari/Firefox stores | native messaging host, extraction, adapters |
| **Archive** (new) | Swift + SQLite | inside Core | index, dedup, search, incremental save |

## Phase 0 — Foundation (no browser dependency)

Everything in Phase 0 is testable without a browser, a network, or a store
account. If the plan is going to slip, it should slip at Phase 1, where the
external dependencies are unavoidable and visible.

**0.1 Conversation model** — `Conversation`, `Turn`, `Role`, `Source`.
Platform-agnostic. Serialised to and from JSON so the bridge and the core can
exchange it.

**0.2 Frontmatter renderer** — YAML block with title, date, platform, model,
url, turn count. Round-trip: the renderer must be able to *read* frontmatter it
wrote, because the archive needs it for dedup and search without re-parsing the
body.

**0.3 Fingerprinting** — content hash over normalised turns, independent of
whitespace and timestamps. This is what makes dedup and incremental save
possible. Getting this wrong silently corrupts archives, so it gets its own
tests: same content reordered in time must collide; genuinely different content
must not.

**0.4 Incremental writer** — given an existing file and a new conversation,
decide: append, merge, replace, or write-new. Never destroys user edits made
outside the tool. This is the single highest-value behaviour and the one most
likely to eat data if implemented naively.

Gate: `tests/ci` green, 153 existing tests still passing.

## Phase 1 — Archive layer (SQLite, still no browser)

The retrieval gap is the moat, and it is also the part nobody else has. It
works on files the user already has, whether they came from this tool, a
competitor extension, or ChatGPT's ZIP.

**1.1 Store** — SQLite at `~/Library/Application Support/Clipboard_saver/archive.db`.
Tables: `documents` (path, title, platform, mtime, turn_count, fingerprint),
`messages` (document, turn, role, body), `tags`.

**1.2 FTS5 index** — index message bodies, not whole files, so search results
can point at a turn rather than a file.

**1.3 Idempotent re-save** — a conversation saved four times is one file with
three links. Backed by 0.3.

**1.4 Search service** — a Services-menu entry. Answers from the pasteboard, no
app launch, no browser. Makes the archive worth having.

**1.5 Dedupe and tags** — content-derived tagging, and exact-duplicate
grouping. *Near*-duplicate collapsing is deliberately **not** built: it needs a
similarity threshold, and a wrong merge destroys a conversation that exists
nowhere else. Exact grouping is free because it is a fingerprint lookup, and it
already catches the common case of the same thread saved repeatedly. Near
duplicate detection is a decision for someone who owns real archives to lose,
not a default.

Gate: FTS5 index rebuilds from disk, search returns turn-level hits, re-save is
idempotent under test.

## Phase 2 — Native messaging bridge

**2.1 Native host** — a small Swift executable registered at
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`. Length-
prefixed framing per the Chrome protocol. It is a *separate binary* from the
Services app, because the host must be launchable without a GUI session.

**2.2 Extraction** — the shim. DOM in, `Conversation` JSON out. Deliberately
dumb; the structural work happens in Core.

**2.3 Adapters** — one per platform, each returning a confidence score. A
confidence drop below threshold is a loud failure, never a quiet short file.
Adapters declare which scroll strategy their platform needs, because the two
platform families behave oppositely (see 2.4).

**2.4 Auto-scroll** — the hardest part, and the part every exporter gets wrong.

Virtualised message lists mean the DOM holds only what is currently mounted.
There are two distinct failure modes, requiring opposite strategies:

- **Infinite scrollers** (Gemini). Old turns stay mounted as you scroll. Scroll
  to the top once, wait for the count to stabilise, read it all. The subtlety is
  that the load trigger is usually *edge-triggered* on a top-crossing event, so
  a second pass from the top does nothing. It has to jump to the bottom first to
  re-arm, then return to the top.
- **Windowing** (Claude, ChatGPT). Off-screen turns are *evicted*. You cannot
  scroll to the top and read everything; you must step upward, harvest each
  window, and accumulate across them, deduplicating on a stable per-turn key.

Three requirements, each learned by a competitor from a shipping bug:

1. **Overlapping steps.** Step by 0.6 of clientHeight, not 1.0. A full-viewport
   step leaves a turn straddling the boundary to fall between two harvests, and
   it is lost silently. This is the single most important constant in the
   feature.
2. **Progress-aware deadlines, not a fixed wall.** Give up after 15s with *no
   progress* (reset on every iteration that surfaces a new turn), plus an
   absolute 5min cap. A fixed wall did not scale: at ~400ms per iteration it
   capped accumulation around 75 turns, so any longer conversation timed out
   mid-scroll. Background-tab timer throttling (≥1s, ~10s after 5min hidden)
   makes any wall-clock budget unreliable anyway.
3. **Stop-and-save with the truncation stated.** A timeout is not a failure, it
   is a partial capture — and a partial capture must say so, in the file, per
   feature 2.3.

Gate: fixture-driven. Saved copies of real chat markup, committed, so adapter
regressions are test failures rather than user bug reports.

## Phase 3 — Distribution

**3.1 Extension packaging** — manifest, three store submissions, permission set
limited to `activeTab` + `storage` (+ narrow host access where images are
required).

**3.2 Zero-network verification** — provable, not claimed. The app opens no
sockets; the extension's full permission set is inspectable.

## Risks

- **The store reviews are the schedule.** Phases 0-1 ship without them. Do not
  let a review queue block archive work that has no external dependency.
- **Adapters rot.** Sites change without notice. Mitigated by fixtures (2.4) and
  the confidence gate (2.3), but this is permanent maintenance, not a one-time
  cost. Budget for it honestly.
- **Safari is a separate implementation.** Its Services restrictions do not
  apply to extensions, but its extension APIs differ enough that `2.1`-`2.4` may
  need a host-shim variant.
- **The `saveToFolder` GUI path is still unverified** in a real Finder run. Cheap
  to fix, and it should be done before Phase 1 claims anything about end-to-end
  behaviour.

## What is deliberately not here

- No accounts, no sync, no server. Everything local. This is a constraint, not
  an omission — a chat archive is exactly the kind of data people will not hand
  to a third party.
- No PDF. The competitor set has it and it is a rendering product, not a
  conversion one.
- No mobile. Requires a different architecture entirely.

## Status

| Phase | State |
|---|---|
| 0 — model, frontmatter, fingerprint, incremental save | done |
| 1 — FTS5 index, search service, tags, dedup | done |
| 2 — protocol, host, extension, adapters, harvester | done, except store submission |
| 3 — store submission | needs your accounts |

## Added after the plan was written

None of these were in the original twenty, and each one cost more in edge cases
than the feature it delivered.

- **Daily notes and destination presets** — a note appended in place, a preset
  resolved to a folder, with a delimited section so a second save updates rather
  than duplicates.
- **KaTeX and MathJax recovery** — an expression that survives the round trip is
  worth more than one that renders nicely once and is unreadable in the file.
- **Selection-scoped capture** — save two messages out of forty, not forty out of
  two.
- **Generic page capture** — a chat has role markers and an article does not, so
  the hard part inverted: deciding which of ten thousand elements is the content.
  Scored on text density, paragraph count and link density, and a low score
  produces a file that says so rather than a confident capture of a sitemap.
- **Attachment references** — recorded, never fetched. The app makes no network
  connections by design, and that is the reason the archive is worth keeping.

## The extension could not load at all

Worth its own section, because every test in the repository passed while the
extension did not work.

`manifest.json` and the entry scripts sat in `extension/` importing modules from
`../src/`. Two browser rules make that unworkable: an extension is a sealed root,
so nothing outside it loads; and an MV3 content script is a classic script, so
`import` is a `SyntaxError` rather than a feature. Every other test imported
`../src/*` directly, which means the packaged files -- the ones Chrome runs --
were never executed by anything.

Two more defects sat behind it. The service worker asked the content script for
`document`, `location` and a `Range`, none of which survive `chrome.runtime`
messaging, which serialises with JSON. And it added a 4-byte length prefix
before `port.postMessage`, on the belief that Chrome passes bytes through; Chrome
adds that prefix itself, so the host read our prefix as the first four bytes of a
JSON document and every request came back malformed.

Fixed by inverting the split: the content script extracts, because it is the
only part that can see the page, and returns plain data; the worker owns the
single host port, because the host serves one connection at a time. `bridge/build.mjs`
flattens the graph into `extension/lib/` with no dependencies, and refuses an
import cycle rather than emitting bindings that would be undefined at runtime.

Chrome's own packer then found a fourth: the keyboard shortcut was written
`Command+Shift+S`, and Chrome rejects a literal `Command` -- the manifest takes
`Ctrl`, which the browser maps per platform. Nothing else in the repository
considered that wrong. `scripts/test.sh` now runs the packer when Chrome is
installed, and asserts the rule so it does not need Chrome to catch it.

## What the tests could not see

Three defects reached `main` with every test in the repository green, and all
three had the same cause: a boundary with nothing crossing it.

1. `bridge/host/build.sh` kept a hand-written list of app sources. Seven files
   were added to the app over time and never added to it, so the host stopped
   compiling the moment the renderer began using `HTMLToMarkdown`. Nothing
   caught it because the Xcode project globs the directory, the Swift tests build
   through Xcode, and only the build script read the stale copy.
2. The extension never sent `conversation.extractedAt`, which the model required.
   Every real save was refused with "could not read the request". The Swift tests
   construct a `BridgeRequest` in Swift; the JavaScript tests never see Swift.
3. The selection path built turns without the shared readers, so selecting a
   message silently dropped its reasoning, tool calls and attachments. The saved
   file looked complete and was not.

The refusals were also uninformative: a version mismatch, a renamed field and a
type change all produced the same sentence. The message now names the field.

`scripts/test.sh` runs the bridge unit tests, builds the host, and drives the
whole path end to end -- extension source, native framing, compiled host, saved
file -- with the payload coming out of the real extractor so it cannot drift from
what the extension sends. A second save is asserted to be a no-op.

## Known limits

- **Extensions do not record the source of a capture.** Chat providers do not
  disclose it, and a guessed model name in frontmatter is worse than none.
- **`saveToDesktop` needs a bundle ID in the services allowlist.** Not available
  to a stock macOS app. `saveToFolder` is unaffected.
- **Adapters rot.** Selectors are pinned to three providers and verified against
  saved pages, not live ones; see below.
- **Attachments are references, not copies.** By design, not by omission.

Verified: 389 Swift tests, 60 extension tests, 0 failures. The host is exercised
over a real pipe, and the harvester against 300 randomised configurations.

## The one thing left that only a person can do

**The adapter selectors are unverified against live sites.** The fixtures under
`bridge/test/fixtures/` are hand-written from the structure the adapters
document, so they verify the adapters' *contract* — role mapping, key
extraction, ordering, title handling, and the confidence reported when a page
does not match — and nothing about whether those selectors match Anthropic's or
OpenAI's current markup. A fixture written from a guess would encode the guess
and then pass by confirming it, which is the same failure mode this project has
been fixing all along.

To close it: open a real conversation, right-click, "Save conversation as
Markdown". Then save the page as HTML and commit it as a fixture. A capture that
comes back marked incomplete, or missing turns, is the adapter failing and the
markup is the evidence.

Everything else in this plan is built and tested. This one needs a browser, an
account, and a real conversation.

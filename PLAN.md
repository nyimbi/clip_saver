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

**1.5 Dedupe and tags** — near-duplicate collapse, content-derived tagging.

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

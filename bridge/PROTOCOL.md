# Native messaging protocol

The browser extension and the native app exchange one thing: a `Conversation`.
The format is length-prefixed JSON over stdio, which is what Chrome's native
messaging requires and what Firefox and Safari's WebExtensions both accept.

## Framing

Native messaging messages are framed, not newline-delimited. A 4-byte
little-endian length prefix followed by exactly that many bytes of UTF-8 JSON.

    +---------------+------------------------+
    | length: uint32| payload: JSON (UTF-8)  |
    | little-endian | exactly `length` bytes |
    +---------------+------------------------+

Newline framing is the obvious choice and it is wrong: a message body
routinely contains newlines, and a `.md` conversation contains thousands of
them. Framing on a delimiter means a transcript with a blank line in it splits
into two malformed messages and the host has to guess.

## Limits

| Limit | Value | Why |
|---|--:|---|
| Max message | 512 MiB | Chrome's own ceiling. A 1,077-turn conversation plus inline images is the worst realistic case; the fixed 1 MiB cap that an earlier version of a competitor used was exceeded by a real conversation and the rejection then surfaced as a `TypeError` in the content script. |
| Max attachments | 20 | Bounds worker memory on a single save. |
| Max single image | 14 MiB | ~10 MB of binary plus base64 overhead. |
| Max total image payload | 48 MiB | Independent of the per-image and per-count caps — 20 × 14 MiB would otherwise let one message reach ~280 MiB. |

## Requests

All messages carry a `version` and an `id`. The `id` is echoed so a
`connectNative` port carrying pipelined requests can be matched to responses;
the protocol is request/response, so a mismatch is a bug, not a feature.

### `saveConversation`

```json
{
  "version": 1,
  "id": "01H...",
  "action": "saveConversation",
  "conversation": { "...Conversation JSON..." },
  "destination": "/Users/you/Documents/Conversations",
  "behaviour": "ask" | "auto"
}
```

`behaviour: "ask"` opens the save panel. `"auto"` writes to a filename derived
from the conversation's own title, which is what the context menu uses: a
right-click that then produces another dialog is two clicks, not one.

The response carries what actually happened, not whether the write appeared to
succeed:

```json
{
  "version": 1,
  "id": "01H...",
  "ok": true,
  "result": {
    "path": "/Users/you/Documents/Conversations/Swift concurrency.md",
    "action": "append",
    "turns": 42,
    "confidence": 0.96,
    "complete": true,
    "incompleteReason": null
  }
}
```

`action` echoes the `SaveAction` the core decided on, so the extension can tell
the user whether the file was new, updated, or written alongside because the
existing one was hand-edited. The last case is the one worth surfacing: the
user pressed save twice, expects one file, and gets a second one.

### `searchArchive`

```json
{ "version": 1, "id": "01H...", "action": "searchArchive", "query": "actors" }
```

Used by a future keyboard command in the extension. Not reachable from the
context menu, which goes straight to a save.

## Errors

Errors are responses, not transport failures. A native messaging port that dies
mid-request gives the extension a generic "An unexpected error occurred", which
is useless for diagnosing a selector that stopped matching.

```json
{
  "version": 1,
  "id": "01H...",
  "ok": false,
  "error": {
    "code": "unwritableDestination",
    "message": "Could not write to /Users/you/Conversations.",
    "recoverable": true
  }
}
```

| Code | Recoverable | Meaning |
|---|:--:|---|
| `unsupportedVersion` | no | Extension is newer or older than the host. The user should update one of them. |
| `malformedRequest` | no | Not valid JSON, or missing a required field. A bug in the extension. |
| `noDestination` | yes | No folder configured and none could be derived. |
| `unwritableDestination` | yes | Permission denied, read-only volume, or a path that does not exist. |
| `extractionFailed` | yes | The adapter found no turns. Carries the reason as `message`. |
| `internalError` | yes | Anything else. The message carries the detail. |

`recoverable: false` means retrying the same request cannot help, so the
extension should not offer a Retry button.

## Trust boundary

The extension is a separate process with its own privileges, and the host holds
the user's filesystem access. Two rules follow:

1. **The host validates everything.** The extension sends a path; the host
   resolves and checks it. A compromised or buggy extension must not be able to
   name an arbitrary destination.
2. **The host never trusts `complete: true`.** The flag is advisory. The host
   recomputes completeness from what it received, because the case that matters
   is a truncated capture written as if it were whole.

The app makes no network connections. The extension's permission set is
inspectable by the user, and that is the whole of the privacy story — it has to
be verifiable rather than promised, because the data is a complete record of
someone's private conversations with an AI.


## Dates

Timestamps are **ISO-8601 strings** in UTC, e.g. `2026-01-01T12:00:00Z`.

This is not Swift's default. `JSONEncoder` writes a `Date` as a `Double` of
seconds since the 2001 reference date, which is unambiguous to Swift and to
nothing else: a sender has to know the reference date in order to subtract it,
and a person reading a captured payload has to recognise it at all.

`conversation.extractedAt` is the one timestamp on the wire. It is optional in
the sense that a sender may omit it, and the app then records the moment of
receipt -- refusing to save a whole conversation over a field the user never
sees is the wrong trade.

`attachments[].kind` is **also optional**, and senders should send `null`
rather than guessing. The table mapping a file extension to a kind lives in the
app, where it has to be right; a second copy in the extension would be one more
thing to drift.

`attachments[].byteSize` is an exact byte count, not a formatted string. A
human-readable size cannot survive a round trip -- 12400 bytes renders as
"12 KB" and reads back as 12000, so the saved file would differ from what was
written and every re-save would look like a hand edit.

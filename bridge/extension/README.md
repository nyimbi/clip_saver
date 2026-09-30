# Loading the extension

The extension is loaded unpacked, but it is **assembled** first.

`manifest.json` and the two entry scripts are sources. They live beside the code
they use, import it as ordinary ES modules, and are not loadable as they stand --
for two reasons that are both browser rules rather than preferences:

- A Chrome extension is a sealed root. Nothing outside `extension/` can be
  loaded, and `../src/adapters.js` is outside it.
- An MV3 content script is a **classic** script. It has no `import` and no module
  graph, so even a copy inside the root would be a `SyntaxError` at load.

So `node build.mjs` resolves the graph and flattens it into one self-contained
script per entry point, in `extension/lib/`, which the manifest names. The build
has no dependencies: the runtime is a page scraper that reads other people's
DOM, and a dependency tree is attack surface in someone else's browser. The six
modules it flattens use named exports and no import cycles, and the cycle is
checked rather than assumed.

`bridge/extension/lib/` is generated and not committed. Run `node build.mjs`, or
just `./scripts/test.sh`, which builds and validates it on every run.

## 1. Build and install the host

```sh
./bridge/host/build.sh
./bridge/host/install.sh
```

The host is a **separate binary** from the app, and has to be. Chrome launches a
native messaging host directly, on a pipe, with no GUI session; the app is an
`LSUIElement` agent whose whole purpose is to be driven by Finder. One binary
cannot be both.

`install.sh` copies the host into the app bundle and writes the native messaging
manifest into the three locations the browsers read it from. It needs the
extension ID, which does not exist until the extension is loaded.

## 2. Load the extension

```sh
(cd bridge && node build.mjs)
```

- **Chrome / Brave / Edge / Arc** — `chrome://extensions`, enable Developer mode,
  "Load unpacked", choose `bridge/extension`.
- **Firefox** — `about:debugging#/runtime/this-firefox`, "Load Temporary Add-on",
  choose `bridge/extension/manifest.json`.

## 3. Finish the host installation

Re-run `install.sh` and paste the extension ID it asks for. Copy it from the
extension's card in `chrome://extensions`.

## What crosses between the two halves

A content script extracts and the worker saves, and the split is not negotiable:
`chrome.runtime` messaging serialises with JSON, so a `Document` or a `Range`
cannot cross it at all. An earlier version of this extension handed both to the
worker and would have failed on the first message in the browser, with no test
anywhere in the repository able to see it.

What crosses now is plain data -- a conversation, a confidence report, a count --
and the content script verifies that it is plain before sending, so a stray
non-serialisable value is reported as itself rather than as a mysterious failure
in the app.

The one native-messaging port lives in the worker, because the host serves a
single connection at a time and two tabs saving at once need something to
serialise them.

## What you can and cannot check here

The selectors in `src/adapters.js` are **unverified against live sites**. The
fixtures under `test/fixtures/` are hand-written from the structure the adapters
document, so they verify the adapters' *contract* — role mapping, key
extraction, ordering, title handling, and the confidence reported when a page
does not match — and nothing more. A fixture written from a guess would encode
the guess and then pass by confirming it.

Fetching a logged-out page does not settle it either. `claude.ai` and
`chatgpt.com` return 403 to a plain request, and `gemini.google.com` returns a
login wall — no conversation in the HTML, so every selector comes back empty
whether it is right or wrong. Only a page saved from a signed-in conversation
can answer the question.

### Checking a real conversation

1. Open a conversation with several exchanges, and scroll so a few are visible.
2. Save the page: `Cmd+S`, or DevTools → the ⋮ menu → "Save all as…". Prefer
   "Webpage, HTML only" — a single file, which is what the checker reads.
3. Run the checker against it:

   ```sh
   node bridge/verify-page.js ~/Downloads/claude.html https://claude.ai/chat/abc123
   ```

   It reports which adapter matched, how many turns were found, the roles, how
   many turns had a stable id rather than a positional fallback, and the
   confidence. `--write-fixture` emits it as a fixture; **review the file before
   committing, because a saved conversation is private.**

If it says the selectors do not match, that is the useful outcome. Copy the
outerHTML of one message from DevTools, look for the marker that identifies who
spoke and any per-message id, and update the adapter in `src/adapters.js`. Then
re-run the checker.

## Permissions

`activeTab`, `contextMenus`, `nativeMessaging`, `storage`, `scripting`, plus host
access for the three supported sites. There is no permission for any other origin
and no network permission at all — the extension reads the page it is on and hands
it to the app. A conversation is exactly the kind of data people will not hand to
a third party, so that has to be checkable rather than claimed.

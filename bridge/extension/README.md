# Loading the extension

The extension is unpacked, not packaged. There is no build step: `manifest.json`
is Manifest V3, the modules are plain ES modules, and nothing needs compiling.

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

- **Chrome / Brave / Edge / Arc** — `chrome://extensions`, enable Developer mode,
  "Load unpacked", choose `bridge/extension`.
- **Firefox** — `about:debugging#/runtime/this-firefox`, "Load Temporary Add-on",
  choose `bridge/extension/manifest.json`.

## 3. Finish the host installation

Re-run `install.sh` and paste the extension ID it asks for. Copy it from the
extension's card in `chrome://extensions`.

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

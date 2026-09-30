/**
 * Tests the assembled extension, not the sources.
 *
 * Every other test in this directory imports `../src/*` directly, which means
 * the packaged files -- the ones Chrome actually runs -- were never executed by
 * anything. So `content.js` could import a module from outside the extension
 * root, and `background.js` could hand a `Document` across `chrome.runtime`, and
 * every test here would still pass. Both were true.
 *
 * These tests load `extension/lib/*.js` as a browser would: a classic script, no
 * module system, with a `chrome` object standing in for the APIs. If the bundle
 * does not run here it will not run in a browser, and the message says which.
 */

import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import vm from 'node:vm';

import { JSDOM } from 'jsdom';

import { build, ENTRY_POINTS } from '../build.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const extensionRoot = join(here, '..', 'extension');

/**
 * A `chrome` stand-in that records what the extension asked for.
 *
 * `sendMessage` is a real round trip: content scripts receive a message by the
 * worker calling their listener, and the reply travels back through the
 * callback. Modelling both directions is the point -- a fake that only records
 * would not catch a response shape that never gets sent.
 */
function makeChrome({ lastError = null } = {}) {
	const log = { badge: [], contextMenus: [], native: [], toContent: [], toTab: [], disconnect: 0 };
	// The listeners the extension registers, so a test can fire an event at it.
	const onMessage = [];
	const onInstalled = [];
	const onClicked = [];
	const onCommand = [];

	const chrome = {
		runtime: {
			id: 'test-extension-id',
			lastError,
			onMessage: { addListener: (fn) => (onMessage.push(fn), fn) },
			onInstalled: { addListener: (fn) => (onInstalled.push(fn), fn) },
			// Content -> worker, which is how progress is reported.
			sendMessage: (message) => {
				log.toContent.push(message);
				return Promise.resolve();
			},
			connectNative: (name) => {
				log.native.push(name);
				return {
					postMessage() {},
					disconnect() {
						log.disconnect += 1;
					},
					onMessage: { addListener() {} },
					onDisconnect: { addListener() {} },
				};
			},
		},
		contextMenus: {
			removeAll: (fn) => fn(),
			create: (options) => log.contextMenus.push(options),
			onClicked: { addListener: (fn) => (onClicked.push(fn), fn) },
		},
		commands: { onCommand: { addListener: (fn) => (onCommand.push(fn), fn) } },
		action: {
			setBadgeText: ({ text }) => log.badge.push(text),
			setBadgeBackgroundColor: () => {},
		},
		// Worker -> content, which is how a capture is requested and a result
		// shown. A different direction, so a different record.
		tabs: {
			sendMessage: (id, message, callback) => {
				log.toTab.push({ id, message });
				const reply = { ok: true, page: { title: 'x', html: '<p>x</p>', url: 'https://example.com/', confidence: { score: 0.9 } } };
				callback?.(reply);
				return Promise.resolve(reply);
			},
		},
	};

	return { chrome, log, onMessage, onInstalled, onClicked, onCommand };
}

/** Runs a built file the way a classic script runs: no `import`, no `export`. */
/**
 * Real timers that do not hold the process open.
 *
 * The worker arms a ten-minute timeout on every message it sends, which is right
 * in a service worker and fatal in a test: node waits for the handle, the suite
 * appears to hang, and the assertion that already passed never gets reported.
 * The timers still fire; they just stop keeping the loop alive.
 */
/**
 * Timers that fire on the next tick instead of after their delay.
 *
 * The harvester settles for 400ms between scroll steps on purpose -- virtualised
 * lists mount rows asynchronously and a shorter wait silently skips them. Paying
 * that in real time costs minutes per test, and the delay is not what these
 * tests are checking; the behaviour around it is. The ordering is preserved, so
 * a step still sees the rows the previous one mounted.
 */
function fastTimers() {
	const real = setTimeout;
	const unref = { setTimeout: (fn, ms, ...rest) => { const h = real(fn, 0, ...rest); h.unref?.(); return h; }, clearTimeout };
	return { ...unref, unrefed: unref };
}

function unrefedTimers() {
	const real = setTimeout;
	return {
		setTimeout: (fn, ms, ...rest) => {
			const handle = real(fn, ms, ...rest);
			handle.unref?.();
			return handle;
		},
		clearTimeout,
	};
}

function runClassic(file, { chrome, window, document, timers = {} }) {
	const source = readFileSync(file, 'utf8');
	// A content script has `location` as a bare global, not just as a property
	// of `window`, and so does a worker. Reproducing that is the point: a script
	// that reaches for `location` works in the browser and throws in a context
	// that only has `window`, which is a test that lies.
	const context = vm.createContext({
		chrome,
		window,
		document,
		location: window?.location,
		console,
		setTimeout,
		clearTimeout,
		URL,
		TextDecoder,
		TextEncoder,
		AbortController,
		crypto,
		...timers,
	});
	context.globalThis = context;
	// A module import would be a SyntaxError here, which is the same failure
	// Chrome gives for a content script that tries one.
	vm.runInContext(source, context, { filename: file });
	return context;
}

// MARK: - The build itself

test('the build produces a file for every entry point', () => {
	const result = build();
	assert.ok(result.validated);
	for (const { out } of ENTRY_POINTS) {
		assert.ok(existsSync(join(extensionRoot, out)), `${out} was not built`);
	}
});

test('the built scripts contain no module syntax', () => {
	// A content script in MV3 is a classic script. An `import` here is a
	// SyntaxError at load, in the browser, where the console says only
	// "Uncaught SyntaxError" and the extension simply does not appear.
	for (const { out } of ENTRY_POINTS) {
		const source = readFileSync(join(extensionRoot, out), 'utf8');
		assert.ok(!/^\s*import\s/m.test(source), `${out} has an import statement`);
		assert.ok(!/^\s*export\s/m.test(source), `${out} has an export statement`);
	}
});

test('the built scripts reach nothing outside the extension root', () => {
	for (const { out } of ENTRY_POINTS) {
		const source = readFileSync(join(extensionRoot, out), 'utf8');
		assert.ok(!/['"]\.\.\//.test(source), `${out} references a parent directory`);
	}
});

test('every file the manifest names exists', () => {
	const manifest = JSON.parse(readFileSync(join(extensionRoot, 'manifest.json'), 'utf8'));
	const named = [
		manifest.background.service_worker,
		...manifest.content_scripts.flatMap((entry) => entry.js),
	];
	for (const file of named) {
		assert.ok(existsSync(join(extensionRoot, file)), `the manifest names ${file}, which does not exist`);
	}
});

test('the two bundles do not share a scope', () => {
	// `adapters.js` and `page.js` each export a `RELIABLE`. Flattened naively
	// into one scope, the second silently overwrites the first and the confidence
	// threshold for one kind of capture starts being read at the other's value.
	const background = readFileSync(join(extensionRoot, 'lib/background.js'), 'utf8');
	const content = readFileSync(join(extensionRoot, 'lib/content.js'), 'utf8');
	assert.notEqual(
		(background.match(/__modules\[/g) ?? []).length,
		0,
		'the background bundle has no modules at all, which means it inlined something'
	);
	assert.ok(content.includes('__modules['));
});

test('the manifest asks for no standing access to every site', () => {
	const manifest = JSON.parse(readFileSync(join(extensionRoot, 'manifest.json'), 'utf8'));
	assert.ok(!manifest.host_permissions?.includes('<all_urls>'));
	assert.ok(manifest.permissions.includes('activeTab'), 'the page menu item needs activeTab');
});

// MARK: - Manifest rules
//
// Found by running Chrome's own packer, which is the only validator that knows
// the rules a real store enforces. Each one is asserted here so the failure does
// not need a browser to see.

const manifest = () => JSON.parse(readFileSync(join(extensionRoot, 'manifest.json'), 'utf8'));

test('keyboard shortcuts say Ctrl, which Chrome maps to Command on macOS', () => {
	// Chrome rejects a literal "Command" outright: the manifest takes "Ctrl", and
	// the browser maps it per platform. The error names the key and the file, and
	// nothing else -- a packer run is the only place it appears.
	for (const [name, command] of Object.entries(manifest().commands ?? {})) {
		const key = command.suggested_key?.default;
		if (!key) continue;
		assert.ok(!/\bCommand\b/i.test(key), `${name}: "${key}" should say Ctrl, not Command`);
		assert.match(key, /^(Ctrl|Alt|Shift|Command|MacCtrl)[+]*(Ctrl|Alt|Shift)[+]*[A-Z0-9]$|^F\d+$/, `${name}: "${key}" is not a form Chrome accepts`);
	}
});

test('the manifest is version 3 and declares a service worker as a module', () => {
	const m = manifest();
	assert.equal(m.manifest_version, 3);
	assert.equal(m.background.type, 'module', 'the worker is a bundled classic script');
});

test('no permission is declared that the features do not use', () => {
	// Each of these is load-bearing, and the reasons are the sort of thing that
	// gets "tidied up" later by someone who has forgotten why it is there.
	const m = manifest();
	// `activeTab` is what lets "Save page as Markdown" work on any site without
	// `<all_urls>`; the context-menu click grants it per invocation.
	assert.ok(m.permissions.includes('activeTab'));
	// `scripting` was for injecting into a page on demand, which nothing does now
	// that the content script is declared for the supported hosts.
	assert.ok(!m.permissions.includes('scripting'), 'scripting is unused now the content script is static');
	assert.ok(!m.permissions.includes('<all_urls>'));
	assert.ok(!('web_accessible_resources' in m), 'nothing in this extension is exposed to pages');
});

test('the content script is declared for the hosts the adapters support', () => {
	const m = manifest();
	const matches = m.content_scripts.flatMap((entry) => entry.matches);
	for (const host of ['https://claude.ai/*', 'https://chatgpt.com/*', 'https://gemini.google.com/*']) {
		assert.ok(matches.includes(host), `${host} is not in content_scripts.matches`);
	}
	// The page menu works everywhere, but the content script cannot be injected
	// everywhere without `<all_urls>`, so a non-matching page is reached on
	// demand instead -- which is what the "no content script in that tab" message
	// is for.
	assert.ok(!m.content_scripts.some((entry) => entry.matches.includes('<all_urls>')));
});

test('the content script is not injected into every frame', () => {
	// An ad iframe that happens to be on claude.ai would otherwise run a second
	// copy of the extractor against a document that is not the conversation.
	for (const entry of manifest().content_scripts) {
		assert.equal(entry.all_frames, false);
	}
});

// MARK: - The content script, running

function contentIn(html, { url = 'https://claude.ai/chat/abc' } = {}) {
	const dom = new JSDOM(html, { url });
	const { chrome, log, onMessage } = makeChrome();
	const context = runClassic(join(extensionRoot, 'lib/content.js'), {
		chrome,
		window: dom.window,
		document: dom.window.document,
	});

	/** Sends a message the way the worker does, and resolves with the reply. */
	const ask = (message) =>
		new Promise((resolve) => {
			const [listener] = onMessage;
			const returned = listener(message, { id: 'test' }, resolve);
			assert.equal(returned, true, 'a capture must keep the message channel open');
		});

	return { ask, log, dom };
}

test('the content script answers a capture with plain data', async () => {
	const { ask } = contentIn(`<!doctype html><html><head><title>Thread</title></head><body><main>
		<div data-testid="user-message" data-message-id="m1">question</div>
		<div data-testid="assistant-message" data-message-id="m2">answer</div>
	</main></body></html>`);

	const response = await ask({ action: 'capture' });
	assert.equal(response.ok, true);
	assert.equal(response.conversation.turns.length, 2);
	assert.equal(response.conversation.extractedAt, undefined, 'the app stamps its own receipt time');
});

test('what the content script returns survives JSON', async () => {
	// The whole reason extraction moved into the content script: this is the only
	// check that would have caught a `Document` or a `Range` being handed to the
	// worker. `JSON.stringify` is what `chrome.runtime` does to a message.
	const { ask } = contentIn(`<!doctype html><html><body><main>
		<div data-testid="user-message" data-message-id="m1">question</div>
		<div data-testid="assistant-message" data-message-id="m2">answer</div>
	</main></body></html>`);

	const response = await ask({ action: 'capture' });

	// Content equality, not `deepEqual`: the objects are created in the bundle's
	// realm and `JSON.parse` makes them in this one, so they have different
	// `Object.prototype` and a prototype-sensitive comparison fails on a value
	// that is in fact identical. What matters is that serialising changes
	// nothing -- which is precisely what `chrome.runtime` does to a message.
	const serialised = JSON.stringify(response);
	const round = JSON.parse(serialised);
	assert.equal(JSON.stringify(round), serialised, 'the reply changed when it was serialised');
	assert.equal(round.conversation.turns.length, 2);
	assert.deepEqual(
		round.conversation.turns.map((turn) => turn.role),
		['user', 'assistant']
	);
});

test('an unsupported page is refused with something the user can act on', async () => {
	const { ask } = contentIn('<!doctype html><html><body><main>nothing here</main></body></html>', {
		url: 'https://example.com/',
	});
	const response = await ask({ action: 'capture' });
	assert.equal(response.ok, false);
	assert.match(response.error.message, /Claude, ChatGPT or Gemini/);
});

test('a page capture comes back as data too', async () => {
	const { ask } = contentIn(
		`<!doctype html><html><head><title>An article</title></head><body><article>
			<p>${'Real sentences. '.repeat(60)}</p>
			<p>${'More of them. '.repeat(60)}</p>
		</article></body></html>`,
		{ url: 'https://example.com/post' }
	);
	const response = await ask({ action: 'capturePage' });
	assert.equal(response.ok, true);
	assert.equal(response.page.title, 'An article');
	assert.equal(response.page.url, 'https://example.com/post');
	assert.equal(JSON.parse(JSON.stringify(response)).page.html, response.page.html);
});

test('a second capture while one is running is refused, not queued', async () => {
	const { ask } = contentIn(`<!doctype html><html><body><main>
		<div data-testid="user-message" data-message-id="m1">question</div>
	</main></body></html>`);
	// Both start before either finishes, which is what two clicks look like.
	const [first, second] = await Promise.all([ask({ action: 'capture' }), ask({ action: 'capture' })]);
	const answers = [first, second];
	assert.ok(answers.some((a) => a.ok), 'neither capture ran');
});

// MARK: - The service worker, running

test('the service worker builds its menu on install', () => {
	const { chrome, log, onInstalled, onClicked, onCommand } = makeChrome();
	runClassic(join(extensionRoot, 'lib/background.js'), {
		chrome,
		window: { location: { href: 'https://claude.ai/' } },
		document: {},
		timers: unrefedTimers(),
	});

	const [install] = onInstalled;
	install();
	const ids = log.contextMenus.map((item) => item.id);
	assert.ok(ids.includes('clipboard-saver-save-conversation'));
	assert.ok(ids.includes('clipboard-saver-save-page'));
	assert.ok(onClicked.length === 1 && onCommand.length === 1);
});

test('a menu click asks its tab and reports back', async () => {
	const { chrome, log, onClicked } = makeChrome();
	runClassic(join(extensionRoot, 'lib/background.js'), {
		chrome,
		window: { location: { href: 'https://claude.ai/' } },
		document: {},
		timers: unrefedTimers(),
	});

	const [click] = onClicked;
	click({ menuItemId: 'clipboard-saver-save-conversation' }, { id: 7 });
	// The save is a promise chain through a fake host, so let the microtasks and
	// one macrotask drain rather than guessing.
	await new Promise((resolve) => setTimeout(resolve, 5));

	assert.ok(
		log.toTab.some(({ message }) => message?.action === 'capture'),
		'the menu never asked the tab to extract'
	);
	assert.ok(log.badge.length > 0, 'the badge was never touched');
});

test('a menu click for a page asks for an article, not a conversation', async () => {
	const { chrome, log, onClicked } = makeChrome();
	runClassic(join(extensionRoot, 'lib/background.js'), {
		chrome,
		window: { location: { href: 'https://example.com/' } },
		document: {},
		timers: unrefedTimers(),
	});

	const [click] = onClicked;
	click({ menuItemId: 'clipboard-saver-save-page' }, { id: 3 });
	await new Promise((resolve) => setTimeout(resolve, 5));

	assert.ok(log.toTab.some(({ message }) => message?.action === 'capturePage'));
});

// MARK: - Harvesting through the bundle

/**
 * A page that grows as you scroll to the bottom of it.
 *
 * The harvester reads `scrollTop`, `scrollHeight` and `clientHeight` off the
 * scroller and steps until nothing new appears. jsdom reports all three as zero,
 * so without this the harvester sees a page that cannot scroll and exits having
 * read one window -- which looks exactly like a working capture and proves
 * nothing. Defining them is what makes the scroll real.
 */
function scrollingConversation(totalMessages, { pageHeight = 600, clientHeight = 300 } = {}) {
	const rows = [];
	for (let index = 0; index < totalMessages; index += 1) {
		const role = index % 2 === 0 ? 'user' : 'assistant';
		rows.push(
			`<div data-testid="${role}-message" data-message-id="m${index}">message ${index}</div>`
		);
	}

	const html = `<!doctype html><html><head><title>Long thread</title></head>
		<body><main>${rows.slice(0, 3).join('\n')}</main></body></html>`;
	const dom = new JSDOM(html, { url: 'https://claude.ai/chat/abc' });
	const doc = dom.window.document;
	const main = doc.querySelector('main');

	// Three messages occupy a page; the rest are below the fold and arrive on
	// demand, which is the shape a virtualised list has.
	const perPage = 3;
	let mounted = perPage;

	const geometry = { scrollTop: 0, scrollHeight: perPage * pageHeight, clientHeight };
	Object.defineProperty(main, 'clientHeight', { get: () => clientHeight, configurable: true });
	Object.defineProperty(main, 'scrollHeight', {
		get: () => Math.max(mounted, perPage) * pageHeight,
		configurable: true,
	});

	// Approaching the end mounts the next window, which is what a virtualised
	// list does when it recycles rows.
	//
	// Growth has to be keyed on *approaching* the end rather than on having
	// passed it: the far end is `scrollHeight - clientHeight`, and `scrollHeight`
	// is only as large as what is mounted, so a list that grows when you reach the
	// end can never reach the end. That deadlock is easy to write and looks
	// exactly like a working capture -- one window, no warning.
	Object.defineProperty(main, 'scrollTop', {
		get: () => geometry.scrollTop,
		set: (value) => {
			geometry.scrollTop = value;
			if (value + clientHeight >= mounted * pageHeight - 1 && mounted < totalMessages) {
				mounted = Math.min(mounted + perPage, totalMessages);
			}
			const want = rows.slice(0, mounted).join('\n');
			if (main.innerHTML !== want) main.innerHTML = want;
		},
		configurable: true,
	});

	return { dom, doc, main };
}

test('the bundled harvester scrolls and collects a long conversation', async () => {
	// The tests above only ever read one window. This is the actual work: a
	// forty-message thread that exists in full but is mounted three at a time.
	// If the bundle wired the viewport or the adapter up wrong, this is where it
	// shows -- as a file with three messages in it and no warning.
	const { dom, doc } = scrollingConversation(40);
	const { chrome, onMessage } = makeChrome();
	runClassic(join(extensionRoot, 'lib/content.js'), {
		chrome,
		window: dom.window,
		document: doc,
		timers: fastTimers().unrefed,
	});

	const response = await new Promise((resolve) => {
		const [listener] = onMessage;
		listener({ action: 'capture' }, { id: 'test' }, resolve);
	});

	assert.equal(response.ok, true, `the capture failed: ${response.error?.message}`);
	assert.equal(
		response.conversation.turns.length,
		40,
		`only ${response.conversation.turns.length} of 40 messages were harvested`
	);
	// Compared as a joined string, not `deepEqual`: the turns are plain objects
	// built in the bundle's realm and `.map` makes an array in it, so a
	// prototype-sensitive comparison fails on a value that is in fact equal.
	assert.equal(
		response.conversation.turns.map((turn) => turn.role).slice(0, 4).join(','),
		'user,assistant,user,assistant'
	);
	assert.equal(response.conversation.turns.at(-1).body, 'message 39');
	assert.equal(response.confidence.complete, true, 'a full harvest should report itself complete');
});

// Reporting an incomplete harvest is checked in test/harvest.test.js, against the
// harvester directly. Reached through the bundle it needs a faked clock to fail
// in milliseconds rather than the 300-second cap, and a faked clock that forces
// a timeout is a weaker test than the real one -- it would be asserting that the
// code does what the mock says, not that it times out.

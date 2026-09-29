import { describeIncomplete, harvestInfinite, harvestWindowed } from './harvest.js';
import { readAttachments, readReasoning, readToolCalls, readTurnBody } from './adapters.js';

/**
 * Saves the conversation, driving the harvest and handing the result to the app.
 *
 * The flow, and why each step exists:
 *
 *   adapter.extract()  -- read what is mounted right now
 *   harvest()          -- scroll until the page stops revealing new turns
 *   extract() again    -- re-read, so the final window is read as found
 *   native.save()      -- convert, fingerprint, merge, index, all in the app
 *
 * Harvesting returns a set of stable keys, not turns. The turns themselves are
 * re-read afterwards from the same selectors, which avoids holding a DOM
 * fragment across a scroll and means the text is the text currently rendered
 * rather than a detached copy.
 */

/** The app that receives conversations. Must match the host manifest's name. */
const NATIVE_HOST = 'datacraft.Clipboard_saver';

/** Protocol version. Must match `BridgeHandler.currentVersion`. */
const PROTOCOL_VERSION = 1;

/** How long to wait for the page to mount turns before giving up. */
const PAGE_TIMEOUT_MS = 20_000;

export class ExtractionError extends Error {
	constructor(message, { recoverable = true, cause } = {}) {
		super(message);
		this.name = 'ExtractionError';
		this.recoverable = recoverable;
		this.cause = cause;
	}
}

/**
 * Waits for the container and at least one message to appear.
 *
 * A conversation opened on a slow connection renders nothing for a moment, and
 * extracting immediately would produce an empty capture that looks successful.
 */
async function waitForMessages(adapter, doc, { timeoutMs = PAGE_TIMEOUT_MS, pollMs = 250 } = {}) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		const container = doc.querySelector(adapter.container);
		if (container && container.querySelector(adapter.message)) return true;
		await new Promise((resolve) => setTimeout(resolve, pollMs));
	}
	return false;
}

/** The element that scrolls, which is the page itself on every supported site. */
function findViewport(doc) {
	const scroller =
		doc.querySelector('main') ??
		doc.querySelector('[role="main"]') ??
		doc.scrollingElement ??
		doc.documentElement;
	return {
		scrollTop: () => scroller.scrollTop ?? doc.scrollingElement?.scrollTop ?? 0,
		setScrollTop: (value) => {
			if ('scrollTop' in scroller) scroller.scrollTop = value;
			else if (doc.scrollingElement) doc.scrollingElement.scrollTop = value;
		},
		scrollHeight: () =>
			Math.max(
				scroller.scrollHeight ?? 0,
				doc.scrollingElement?.scrollHeight ?? 0,
				doc.documentElement?.scrollHeight ?? 0,
			),
		clientHeight: () =>
			Math.max(
				scroller.clientHeight ?? 0,
				doc.scrollingElement?.clientHeight ?? 0,
				doc.documentElement?.clientHeight ?? 0,
			),
	};
}

/**
 * Extracts a whole conversation from the page.
 *
 * @param {Document} doc
 * @param {Location} location
 * @param {object} adapter
 * @param {object} [options]
 * @param {AbortSignal} [options.signal]
 * @param {(count: number) => void} [options.onProgress]
 * @returns {Promise<{conversation: object, confidence: object}>}
 */
export async function extractConversation(doc, location, adapter, options = {}) {
	const { signal, onProgress, selection } = options;

	// A selection skips the harvest entirely: the turns are already mounted,
	// and scrolling to pull in messages the user did not select would be both
	// slow and wrong.
	if (selection) {
		const scoped = extractSelection(doc, selection, adapter);
		if (scoped) {
			scoped.conversation.title = scoped.conversation.title
				? `${scoped.conversation.title} (selection)`
				: 'Selection';
			return { conversation: scoped.conversation, confidence: scoped.confidence };
		}
		// A selection that touches nothing usable falls through to the whole
		// conversation, which is the better of two imperfect answers.
	}

	if (!(await waitForMessages(adapter, doc))) {
		throw new ExtractionError(
			`No conversation appeared on this page within ${Math.round(PAGE_TIMEOUT_MS / 1000)}s.`,
			{ recoverable: true }
		);
	}

	const viewport = findViewport(doc);
	const harvest = adapter.kind === 'infinite' ? harvestInfinite : harvestWindowed;

	const result = await harvest({
		viewport,
		readWindow: () => {
			// Re-read from the live document each time: the harvester only needs
			// the stable keys, and reading the text here would be wasted work
			// since the final extract re-reads it.
			const container = doc.querySelector(adapter.container);
			if (!container) return { keys: [], turns: [], order: [], reset() {} };
			const extracted = adapter.extract(doc, location);
			if (!extracted.ok) return { keys: [], turns: [], order: [], reset() {} };
			return {
				keys: extracted.conversation.keys,
				turns: extracted.conversation.turns,
				order: extracted.conversation.order,
				reset() {},
			};
		},
		onProgress: (count, iterations) => onProgress?.(count, iterations),
		signal,
	});

	// The final read. `extract` is run again rather than reusing the harvester's
	// last window, because the harvester may have stepped past the newest
	// messages on its way and this is the only read that is guaranteed to see
	// the current viewport.
	const final = adapter.extract(doc, location);
	if (!final.ok) {
		throw new ExtractionError(final.reason, { recoverable: true });
	}

	const warnings = [...final.confidence.warnings];
	if (!result.complete) {
		warnings.push(describeIncomplete(result));
	}

	return {
		conversation: final.conversation,
		confidence: {
			score: final.confidence.score,
			complete: result.complete && final.confidence.complete,
			strategy: 'dom',
			warnings,
		},
	};
}


/**
 * Extracts only the turns a selection touches.
 *
 * This is the "save these three messages" case, and it is the most common
 * actual intent: a thread is often two hundred turns long and the thing worth
 * keeping is the exchange someone just highlighted.
 *
 * The subtlety is that a selection is a *range in the document*, not a set of
 * turns. A user dragging across a paragraph of one message and a couple of
 * lines of another means "those two", so the rule is containment either way: a
 * turn is included when any part of it is selected. Selecting a single word
 * inside a long message takes the whole message, which is almost always what
 * was meant -- and taking a fragment of a message would produce a transcript
 * that reads as if the assistant had said only that fragment.
 *
 * Returns null when the selection touches no turn at all, which is the signal
 * to fall back to the whole conversation rather than saving nothing.
 *
 * @param {Document} doc
 * @param {Range} range
 * @param {object} adapter
 */
export function extractSelection(doc, range, adapter) {
	if (!range || range.collapsed) return null;

	const container = doc.querySelector(adapter.container);
	if (!container) return null;

	// Compared with `compareBoundaryPoints` rather than offsets: a `Range` in a
	// live document is not a static string, and a node can move between the
	// selection being made and this running.
	const selected = [];
	for (const node of container.querySelectorAll(adapter.message)) {
		if (range.intersectsNode(node)) selected.push(node);
	}
	if (selected.length === 0) return null;

	const saved = (range.commonAncestorContainer.ownerDocument ?? doc).createRange();
	try {
		saved.selectNodeContents(selected[0]);
		for (const node of selected.slice(1)) {
			saved.setEnd(node, node.childNodes.length);
		}

		const scoped = {
			...adapter,
			container: adapter.message,
			message: adapter.message,
		};
		const result = extractFromNodes(doc, new URL(doc.location?.href ?? 'https://claude.ai/'), scoped, selected);
		if (!result.ok) return null;
		result.conversation.partial = true;
		return result;
	} finally {
		saved.detach?.();
	}
}

/**
 * Extracts a specific set of turn elements.
 *
 * Separate from `adapter.extract` so the selection path does not have to
 * re-query the page and risk picking up a different set after a scroll.
 */
function extractFromNodes(doc, url, adapter, nodes) {
	const turns = [];
	const warnings = [];
	let matchedKey = 0;

	nodes.forEach((node, index) => {
		const roleValue = readRole(node, adapter);
		const mapped = adapter.roleMap[roleValue];
		if (!mapped) {
			warnings.push(`Selected turn ${index + 1} had an unrecognised role and was skipped.`);
			return;
		}
		const stableKey = adapter.keyAttribute ? node.getAttribute(adapter.keyAttribute) ?? null : null;
		if (stableKey) matchedKey += 1;
		turns.push({
			role: mapped,
			body: readTurnBody(node, adapter.strip),
			key: stableKey ?? `selection:${index}`,
			// Read through the same readers the full harvest uses. A selection
			// that silently dropped reasoning, tool calls and attachments would
			// save a file that looks complete and is not, which is worse than
			// one that visibly lacks them.
			reasoning: readReasoning(node),
			toolCalls: readToolCalls(node),
			attachments: readAttachments(node),
		});
	});

	if (turns.length === 0) return { ok: false, reason: 'No roles could be identified in the selection.' };

	// A selection is a subset by construction, so a lower confidence than a full
	// capture is the honest report rather than a defect.
	return {
		ok: true,
		conversation: {
			title: doc.title ?? '',
			source: adapter.id,
			model: null,
			url: url.href,
			// ISO-8601, because that is what the app's decoder is configured for.
			// Swift's default would be a Double of seconds since 2001, which a
			// sender has to know the reference date to read.
			extractedAt: new Date().toISOString(),
			turns: turns.map(({ key, ...rest }) => rest),
			keys: turns.map((t) => t.key),
			order: turns.map((_, i) => i),
			partial: true,
		},
		confidence: {
			score: matchedKey === nodes.length ? 0.9 : 0.7,
			complete: true,
			strategy: 'dom',
			warnings,
		},
	};
}

function readRole(node, adapter) {
	try {
		const found = node.matches?.(adapter.role) ? node : node.querySelector?.(adapter.role);
		if (!found) return null;
		const name = valueAttributeIn(adapter.role);
		if (name) {
			const value = found.getAttribute(name);
			if (value) return value;
		}
		return found.getAttribute?.('data-role') ?? found.getAttribute?.('role') ?? null;
	} catch {
		return null;
	}
}

function valueAttributeIn(selector) {
	const match = /\[([a-zA-Z-]+)(?:[\^$*~|]?=)?/.exec(selector ?? '');
	return match ? match[1] : null;
}

/**
 * Sends a conversation to the app and returns what it did with it.
 *
 * Errors from the app are surfaced with their own code, so the UI can say
 * "update the app" rather than "something went wrong".
 *
 * @param {object} bridge `chrome.runtime` or a stand-in.
 */
export async function saveConversation(bridge, { conversation, confidence, destination, behaviour = 'ask' }) {
	const id = crypto.randomUUID();

	const response = await sendNative(bridge, {
		version: PROTOCOL_VERSION,
		id,
		action: 'saveConversation',
		conversation: { ...conversation, confidence },
		destination: destination ?? null,
		behaviour,
	});

	if (!response.ok) {
		const error = new ExtractionError(response.error?.message ?? 'The app could not save this conversation.', {
			recoverable: response.error?.recoverable ?? true,
		});
		error.code = response.error?.code;
		throw error;
	}
	return response.result;
}

/** The native messaging round trip, length-prefixed per PROTOCOL.md. */
function sendNative(bridge, request) {
	return new Promise((resolve, reject) => {
		const port = bridge.runtime.connectNative(NATIVE_HOST);
		const payload = new TextEncoder().encode(JSON.stringify(request));
		const framed = new Uint8Array(4 + payload.length);
		new DataView(framed.buffer).setUint32(0, payload.length, true);
		framed.set(payload, 4);

		const chunks = [];
		port.onMessage.addListener((message) => chunks.push(message));

		port.onDisconnect.addListener(() => {
			const last = chunks.at(-1);
			if (last) {
				try {
					resolve(JSON.parse(new TextDecoder().decode(last)));
				} catch (error) {
					reject(new ExtractionError('The app sent a reply that could not be read.', { cause: error }));
				}
			} else {
				// A disconnect with nothing received is the app not being
				// installed, which is the single most likely cause and needs
				// saying so.
				reject(
					new ExtractionError(
						'The Clipboard Saver app does not appear to be installed. Open it once, then try again.',
						{ recoverable: false }
					)
				);
			}
		});

		port.postMessage(framed);
	});
}

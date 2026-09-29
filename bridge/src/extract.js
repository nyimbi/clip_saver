import { describeIncomplete, harvestInfinite, harvestWindowed } from './harvest.js';

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
	const { signal, onProgress } = options;

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

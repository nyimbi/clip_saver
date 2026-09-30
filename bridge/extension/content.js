/**
 * The content script: the only part of the extension that can see the page.
 *
 * It does nothing on load. No observers, no DOM queries, no injected CSS -- it
 * registers one listener and waits. A content script that touches the page on
 * every navigation is a content script that can break a page it was only meant
 * to read, and the extraction needs a specific moment, which is when the user
 * asks for it.
 *
 * The extraction happens *here*, and that is the whole point of this file's
 * shape. It used to hand `document`, `location` and a `Range` to the service
 * worker and let it do the work, which cannot work: `chrome.runtime` messaging
 * serialises with JSON, and none of those three survive it. `Document` is not
 * serialisable at all, and a `Range` is anchored to nodes that a scroll
 * invalidates. So the old design would have failed at the first message, in the
 * browser, with "An unexpected error occurred" -- after every test in the
 * repository had passed.
 *
 * What crosses the boundary now is plain JSON: a conversation, a confidence
 * report, and a count. That is a smaller payload, it is testable, and it is the
 * only shape the transport actually supports.
 */

import { adapterFor } from '../src/adapters.js';
import { extractConversation, extractSelection, ExtractionError } from '../src/extract.js';
import { extractPage } from '../src/page.js';

/** The in-flight capture, so a second request does not start a second harvest. */
let running = null;

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
	switch (message?.action) {
		case 'capture':
			capture(message).then(sendResponse, (error) => sendResponse(failure(error)));
			// Keeps the message channel open for the async reply. Without this the
			// worker sees an empty response the moment this function returns, long
			// before a scroll-heavy harvest has finished.
			return true;

		case 'capturePage':
			try {
				sendResponse(capturePage());
			} catch (error) {
				sendResponse(failure(error));
			}
			return undefined;

		case 'cancel':
			running?.abort();
			return undefined;

		case 'notify':
			showToast(message);
			return undefined;

		default:
			return undefined;
	}
});

/**
 * Harvests the conversation and returns it as data.
 *
 * The abort controller lives here rather than in the worker because the work
 * lives here: a content script is not suspended mid-task the way a service
 * worker is, so a long scroll that a worker might lose is safe.
 */
async function capture({ behaviour = 'auto' } = {}) {
	if (running) {
		return { ok: false, error: { message: 'A capture is already running in this tab.', recoverable: true } };
	}

	const controller = new AbortController();
	running = controller;

	try {
		const adapter = adapterFor(window.location);
		if (!adapter) {
			throw new ExtractionError(
				'This page is not a supported conversation. Open Claude, ChatGPT or Gemini.',
				{ recoverable: false }
			);
		}

		const selection = currentSelection();
		const { conversation, confidence } = await extractConversation(
			document,
			// A plain object rather than `location`, which is not serialisable
			// either. The extractors read `href` and `hostname` and nothing else.
			{ href: location.href, hostname: location.hostname },
			adapter,
			{
				signal: controller.signal,
				selection,
				// Progress is fire-and-forget up to the worker, which owns the
				// badge. Awaiting it would make the scroll wait on a badge paint.
				onProgress: (count) => {
					chrome.runtime.sendMessage({ action: 'progress', count }).catch(() => {});
				},
			}
		);

		// Verified here rather than trusted: the one thing this boundary must
		// never do is hand the app something it cannot serialise.
		assertPlainData(conversation, 'conversation');

		return { ok: true, conversation, confidence, behaviour };
	} catch (error) {
		return failure(error);
	} finally {
		running = null;
	}
}

/** The user's selection, if it spans any messages, as a range we own. */
function currentSelection() {
	const active = document.getSelection();
	if (!active || active.rangeCount === 0 || active.isCollapsed) return null;
	try {
		return active.getRangeAt(0).cloneRange();
	} catch {
		// A selection can vanish between the check and the read, and a range
		// whose nodes have moved throws rather than returning something wrong.
		return null;
	}
}

function capturePage() {
	// Reached only from the context menu, so `activeTab` has been granted for
	// this page and no standing host access is needed.
	const result = extractPage(document, new URL(location.href));
	if (!result.ok) {
		return { ok: false, error: { message: result.reason, recoverable: false } };
	}
	return {
		ok: true,
		page: {
			html: result.html,
			title: result.title,
			url: location.href,
			confidence: result.confidence,
		},
	};
}

function failure(error) {
	return {
		ok: false,
		error: {
			message: error?.message ?? 'The capture failed.',
			recoverable: error?.recoverable ?? true,
			code: error?.code ?? null,
		},
	};
}

/**
 * Rejects anything that would not survive the trip.
 *
 * A hand-written check rather than a try/catch on the far side, because the far
 * side cannot tell the difference between "the page sent something odd" and "the
 * app is broken", and it will report it as the latter. Finding out here names
 * the field and the phase.
 */
function assertPlainData(value, label, depth = 0) {
	if (depth > 8) throw new ExtractionError(`The ${label} is nested too deeply to send.`, { recoverable: false });
	if (value === null || value === undefined) return;

	const type = typeof value;
	if (type === 'string' || type === 'boolean') return;
	if (type === 'number') {
		if (!Number.isFinite(value)) throw new ExtractionError(`The ${label} contains a number JavaScript cannot send.`);
		return;
	}
	if (Array.isArray(value)) {
		value.forEach((item, index) => assertPlainData(item, `${label}[${index}]`, depth + 1));
		return;
	}
	if (type === 'object') {
		const prototype = Object.getPrototypeOf(value);
		// A plain object's prototype is null or Object.prototype. A Date, a DOM
		// node, a Map, a class instance -- anything else -- is exactly what
		// messaging drops silently.
		if (prototype !== null && prototype !== Object.prototype) {
			throw new ExtractionError(
				`The ${label} contains a ${value.constructor?.name ?? 'non-plain'} value, which cannot cross into the app.`,
				{ recoverable: false }
			);
		}
		for (const [key, item] of Object.entries(value)) assertPlainData(item, `${label}.${key}`, depth + 1);
		return;
	}
	throw new ExtractionError(`The ${label} contains a ${type}, which cannot cross into the app.`);
}

// MARK: - Toast

let toast;

function showToast({ ok, message }) {
	toast?.remove();

	toast = document.createElement('div');
	// textContent, never innerHTML: this runs in someone else's page, and the
	// message can carry a filename from that page.
	toast.textContent = message;
	Object.assign(toast.style, {
		position: 'fixed',
		right: '16px',
		bottom: '16px',
		zIndex: '2147483647',
		maxWidth: '380px',
		padding: '10px 14px',
		borderRadius: '8px',
		font: '13px/1.4 -apple-system, BlinkMacSystemFont, sans-serif',
		color: '#fff',
		background: ok ? '#2e7d32' : '#c62828',
		boxShadow: '0 4px 16px rgba(0,0,0,0.25)',
		// Injected into someone's page, so it is scoped to this element and
		// removed on its own rather than left to accumulate.
		pointerEvents: 'none',
	});
	document.body.appendChild(toast);
	setTimeout(() => toast?.remove(), 6000);
}

/**
 * The content script: exposes the page to the service worker and shows results.
 *
 * Deliberately does nothing on load. No observers, no DOM queries, no injected
 * CSS -- it registers one message listener and waits. A content script that
 * touches the page on every navigation is a content script that can break a page
 * it was only meant to read, and there is nothing to gain from it here: the
 * extraction needs a specific moment, and that moment is when the user asks.
 */

import { adapterFor } from './adapters.js';

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
	switch (message?.action) {
		case 'extract': {
			const adapter = adapterFor(window.location);
			if (!adapter) {
				sendResponse({ supported: false });
				return;
			}
			// The document is passed by reference within the same realm, so the
			// service worker's extraction runs against the live page.
			sendResponse({
				supported: true,
				document,
				location: { href: location.href, hostname: location.hostname },
				adapter: serialiseAdapter(adapter),
			});
			return;
		}

		case 'cancel':
			sendResponse({ ok: true });
			return;

		case 'notify':
			showToast(message);
			sendResponse({ ok: true });
			return;

		default:
			return;
	}
});

/**
 * The adapter as plain data.
 *
 * Structured clone drops functions, so the object literal in the adapter is
 * sent across instead of the instance. The `extract` method is re-attached by
 * the service worker side, which is why `adapters.js` is a definition rather
 * than a class with a prototype.
 */
function serialiseAdapter(adapter) {
	return {
		id: adapter.id,
		displayName: adapter.displayName,
		hostnames: adapter.hostnames,
		kind: adapter.kind,
		container: adapter.container,
		message: adapter.message,
		role: adapter.role,
		keyAttribute: adapter.keyAttribute,
		model: adapter.model,
		title: adapter.title,
		roleMap: adapter.roleMap,
		strip: adapter.strip,
	};
}

// MARK: - Toast

let toast;

function showToast({ ok, message }) {
	toast?.remove();

	toast = document.createElement('div');
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

/**
 * The service worker: menu, keyboard command, badge, and the one host port.
 *
 * It does not see any pages and does not need to. A content script extracts and
 * hands back plain data; this file decides what to do with it. That split is not
 * a preference -- `chrome.runtime` messaging serialises with JSON, so a
 * `Document` or a `Range` cannot be sent here at all, and the previous design
 * asked for exactly that.
 *
 * The host connection lives here rather than in the content script for one
 * concrete reason: the native host serves one connection at a time, so two tabs
 * saving at the same moment need something to serialise them. One port, in one
 * place, does that. A content script per tab would open one each.
 */

import { saveConversation } from '../src/extract.js';

const MENU_SAVE = 'clipboard-saver-save-conversation';
const MENU_SAVE_PAGE = 'clipboard-saver-save-page';
const MENU_CANCEL = 'clipboard-saver-cancel';

// MARK: - Menu

chrome.runtime.onInstalled.addListener(() => {
	chrome.contextMenus.removeAll(() => {
		chrome.contextMenus.create({
			id: MENU_SAVE,
			title: 'Save conversation as Markdown',
			// `page` rather than `selection` first: saving the whole conversation
			// is the common case, and a selection-scoped variant is a separate
			// menu item rather than a modifier, so it stays discoverable.
			contexts: ['page'],
		});
		chrome.contextMenus.create({
			id: MENU_SAVE_PAGE,
			title: 'Save page as Markdown',
			// `page` on any host, not just the three supported ones. A
			// context-menu click grants `activeTab` for that page, so this needs
			// no standing access to every site the user visits -- which is the
			// whole reason a generic page capture can exist without `<all_urls>`.
			contexts: ['page'],
		});
		chrome.contextMenus.create({
			id: MENU_CANCEL,
			title: 'Stop capturing',
			contexts: ['page'],
			visible: false,
		});
	});
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
	if (!tab?.id) return;
	if (info.menuItemId === MENU_CANCEL) {
		chrome.tabs.sendMessage(tab.id, { action: 'cancel' }).catch(() => {});
		return;
	}
	if (info.menuItemId === MENU_SAVE) captureConversation(tab.id);
	if (info.menuItemId === MENU_SAVE_PAGE) captureArticle(tab.id);
});

chrome.commands.onCommand.addListener(async (command) => {
	if (command !== 'save-conversation') return;
	const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
	if (tab?.id) captureConversation(tab.id);
});

/** Progress and completion, from whichever content script is working. */
chrome.runtime.onMessage.addListener((message) => {
	if (message?.action === 'progress') {
		chrome.action.setBadgeText({ text: message.count ? String(message.count) : '…' });
	}
});

// MARK: - Capture

/** Tabs with a capture in flight, so a second click does not start a second. */
const running = new Set();

async function captureConversation(tabId) {
	if (running.has(tabId)) return;
	running.add(tabId);
	await badge(tabId, '…');

	try {
		const response = await sendToTab(tabId, { action: 'capture' });
		if (!response?.ok) throw response?.error ?? { message: 'The page did not answer.' };

		// `behaviour: 'ask'` from the menu, so the user chooses the folder.
		// The command key skips the prompt, which is the point of a shortcut.
		const result = await save(chrome.runtime, {
			conversation: response.conversation,
			confidence: response.confidence,
			behaviour: 'ask',
		});

		await finish(tabId, summarise(result, response.confidence));
	} catch (error) {
		await finish(tabId, { ok: false, message: error?.message ?? 'The capture failed.' });
	} finally {
		running.delete(tabId);
	}
}

async function captureArticle(tabId) {
	await badge(tabId, '…');

	try {
		const response = await sendToTab(tabId, { action: 'capturePage' });
		if (!response?.ok) throw response?.error ?? { message: 'This page could not be read.' };

		const result = await save(chrome.runtime, {
			conversation: {
				title: response.page.title,
				source: 'web',
				model: null,
				// The page's own URL, not null. The article belongs somewhere, and
				// the frontmatter is where a reader will look for it.
				url: response.page.url ?? null,
				// `format: 'html'` tells the app to convert, so the structural
				// converter stays in Swift with its 64 tests behind it rather than
				// being reimplemented in JavaScript here.
				turns: [{ role: 'assistant', body: response.page.html, format: 'html' }],
			},
			confidence: response.page.confidence,
			behaviour: 'ask',
		});

		await finish(tabId, summarise(result, response.page.confidence));
	} catch (error) {
		await finish(tabId, { ok: false, message: error?.message ?? 'The capture failed.' });
	}
}

/**
 * One save at a time.
 *
 * The host serves a single connection, and two of them at once produce two
 * half-read streams rather than an error. Queueing costs the second tab a
 * moment; not queueing costs it a corrupted file, silently.
 */
let queue = Promise.resolve();

function save(bridge, request) {
	const next = queue.then(() => saveConversation(bridge, request));
	// A rejection must not poison the queue for every later save.
	queue = next.catch(() => {});
	return next;
}

/**
 * A one-line account of what the app did.
 *
 * The interesting case is `writeAlongside`: the user saved twice, expects one
 * file, and got a second. Saying so is the difference between a confusing
 * duplicate and a comprehensible one.
 */
function summarise(result, confidence) {
	if (!result?.path) return { ok: true, message: 'Already saved — nothing changed.' };
	const name = result.path.split('/').pop();
	switch (result.action) {
		case 'append':
			return { ok: true, message: `Added new messages to ${name}` };
		case 'writeAlongside':
			return {
				ok: true,
				message: `${name} has changes this app did not make, so this was saved as a new file instead.`,
			};
		default:
			return { ok: true, message: `Saved ${name}` };
	}
}

async function badge(tabId, text) {
	await chrome.action.setBadgeText({ text });
	await chrome.action.setBadgeBackgroundColor({ color: '#2e7d32' });
}

async function finish(tabId, payload) {
	// The page may have navigated while the harvest was running, in which case
	// there is nobody left to tell and the badge is the only place the result can
	// appear. Neither failing is worth surfacing to the user.
	await chrome.tabs.sendMessage(tabId, { action: 'notify', ...payload }).catch(() => {});
	await chrome.action.setBadgeBackgroundColor({ color: payload.ok ? '#2e7d32' : '#c62828' });
	await chrome.action.setBadgeText({ text: payload.ok ? '✓' : '!' });
	setTimeout(() => chrome.action.setBadgeText({ text: '' }).catch(() => {}), 4000);
}

/**
 * Asks the content script, and treats silence as a page we cannot act on.
 *
 * The service worker can be suspended, so this has a timeout rather than waiting
 * forever on a channel that may never open. A reply that arrives after it is
 * dropped, which is fine: the worker is gone and nobody is waiting.
 */
function sendToTab(tabId, message, timeoutMs = 600_000) {
	return new Promise((resolve) => {
		let settled = false;
		const finish = (value) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			resolve(value);
		};
		const timer = setTimeout(() => finish({ ok: false, error: { message: 'The page did not answer in time.' } }), timeoutMs);

		chrome.tabs
			.sendMessage(tabId, message, (response) => {
				// A content script that is not there is a page we cannot act on --
				// a page loaded before the extension was installed, or one whose
				// host is not in `matches`. Not an error worth surfacing as one.
				finish(chrome.runtime.lastError ? { ok: false, error: { message: 'No content script in that tab. Reload the page and try again.' } } : response);
			});
	});
}

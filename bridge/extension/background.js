/**
 * The service worker: context menu, keyboard command, and the badge.
 *
 * Nothing structural happens here. The content script extracts, this file
 * relays, and the app saves. Keeping it that thin means there is one place to
 * look when a save does not appear, and it is small.
 */

import { adapterFor } from './adapters.js';
import { ExtractionError, extractConversation, saveConversation } from './extract.js';

const MENU_SAVE = 'clipboard-saver-save-conversation';
const MENU_CANCEL = 'clipboard-saver-cancel';
const HOSTNAME_WHITELIST = new Set(['claude.ai', 'chatgpt.com', 'chat.openai.com', 'gemini.google.com']);

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
			id: MENU_CANCEL,
			title: 'Stop capturing',
			contexts: ['page'],
			visible: false,
		});
	});
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
	if (info.menuItemId === MENU_CANCEL) {
		chrome.tabs.sendMessage(tab.id, { action: 'cancel' });
		return;
	}
	if (info.menuItemId !== MENU_SAVE || !tab?.id) return;
	await capture(tab.id, { behaviour: 'ask' });
});

chrome.commands.onCommand.addListener(async (command) => {
	if (command !== 'save-conversation') return;
	const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
	if (!tab?.id) return;
	await capture(tab.id, { behaviour: 'auto' });
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
	if (message?.action === 'progress') {
		chrome.action.setBadgeText({ text: message.count ? String(message.count) : '' });
		return;
	}
	if (message?.action === 'done') {
		chrome.action.setBadgeText({ text: '' });
		return;
	}
	return undefined;
});

// MARK: - Capture

/** The in-flight capture per tab, so it can be cancelled. */
const running = new Map();

async function capture(tabId, { behaviour }) {
	if (running.has(tabId)) return;

	const controller = new AbortController();
	running.set(tabId, controller);
	chrome.action.setBadgeText({ text: '…' });

	try {
		const response = await sendToTab(tabId, { action: 'extract' });
		if (!response?.supported) {
			throw new ExtractionError(
				'This page is not a supported conversation. Open Claude, ChatGPT or Gemini.',
				{ recoverable: false }
			);
		}

		const { conversation, confidence } = await extractConversation(
			response.document,
			response.location,
			response.adapter,
			{
				signal: controller.signal,
				selection: response.selection,
				onProgress: (count) => chrome.tabs.sendMessage(tabId, { action: 'progress', count }),
			}
		);

		const result = await saveConversation(chrome.runtime, {
			conversation,
			confidence,
			behaviour,
		});

		await notify(tabId, summarise(result, confidence));
	} catch (error) {
		await notify(tabId, {
			ok: false,
			message: error?.recoverable === false ? `${error.message}` : error?.message ?? 'The capture failed.',
		});
	} finally {
		running.delete(tabId);
		chrome.action.setBadgeText({ text: '' });
	}
}

/**
 * A one-line account of what the app did.
 *
 * The interesting case is `writeAlongside`: the user saved twice, expects one
 * file, and got a second. Saying so is the difference between a confusing
 * duplicate and a comprehensible one.
 */
function summarise(result, confidence) {
	if (!result?.path) {
		return { ok: true, message: 'Already saved — nothing changed.' };
	}
	const name = result.path.split('/').pop();
	switch (result.action) {
		case 'writeNew':
			return { ok: true, message: `Saved ${name}` };
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

async function notify(tabId, payload) {
	chrome.tabs.sendMessage(tabId, { action: 'notify', ...payload });
	chrome.action.setBadgeBackgroundColor({ color: payload.ok ? '#2e7d32' : '#c62828' });
	chrome.action.setBadgeText({ text: payload.ok ? '✓' : '!' });
	setTimeout(() => chrome.action.setBadgeText({ text: '' }), 4000);
}

function sendToTab(tabId, message) {
	return new Promise((resolve) => {
		chrome.tabs.sendMessage(tabId, message, (response) => {
			// A content script that is not there is a page we cannot act on, not
			// an error worth surfacing as one.
			resolve(chrome.runtime.lastError ? { supported: false } : response);
		});
	});
}

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { JSDOM } from 'jsdom';

import { extractSelection } from '../src/extract.js';

const here = dirname(fileURLToPath(import.meta.url));
const claudeURL = 'https://claude.ai/chat/abc';

/** The Claude adapter, as the content script sends it across the boundary. */
const adapter = {
	id: 'claude',
	kind: 'windowed',
	container: 'main',
	message: '[data-testid^="user-message"], [data-testid^="assistant-message"]',
	role: '[data-testid^="user-message"], [data-testid^="assistant-message"]',
	keyAttribute: 'data-message-id',
	roleMap: { 'user-message': 'user', 'assistant-message': 'assistant' },
	strip: ['button', '[data-testid="copy-button"]'],
};

function load() {
	const html = readFileSync(join(here, 'fixtures', 'claude-conversation.html'), 'utf8');
	const dom = new JSDOM(html, { url: claudeURL });
	dom.window.document.location = dom.window.location;
	return dom.window.document;
}

/** Selects from the start of one message node to the end of another. */
function rangeAcross(doc, firstSelector, firstOffset, lastSelector, lastOffset) {
	const range = doc.createRange();
	range.setStart(doc.querySelector(firstSelector), firstOffset);
	range.setEnd(doc.querySelector(lastSelector), lastOffset);
	return range;
}

test('a selection spanning two messages takes those two', () => {
	const doc = load();
	const range = rangeAcross(
		doc,
		'[data-testid="assistant-message"][data-message-id="m2"] p',
		0,
		'[data-testid="user-message"][data-message-id="m3"] p',
		1
	);
	const result = extractSelection(doc, range, adapter);

	assert.ok(result, 'a selection across two messages produced nothing');
	assert.equal(result.conversation.turns.length, 2);
	assert.deepEqual(result.conversation.turns.map((t) => t.role), ['assistant', 'user']);
});

test('a selection inside one message takes that whole message', () => {
	// Taking a fragment would produce a transcript that reads as though the
	// assistant had said only the selected words, which is almost never meant.
	const doc = load();
	const paragraph = doc.querySelector('[data-message-id="m1"] p');
	const range = doc.createRange();
	// A single word out of the middle of the sentence.
	range.setStart(paragraph.firstChild, 5);
	range.setEnd(paragraph.firstChild, 9);

	const result = extractSelection(doc, range, adapter);
	assert.equal(result.conversation.turns.length, 1);
	assert.match(result.conversation.turns[0].body, /How do I run two async calls concurrently\?/);
});

test('a selection over a whole conversation takes every message', () => {
	const doc = load();
	const main = doc.querySelector('main');
	const range = doc.createRange();
	range.selectNodeContents(main);

	const result = extractSelection(doc, range, adapter);
	assert.equal(result.conversation.turns.length, 4);
});

test('a collapsed selection yields nothing', () => {
	const doc = load();
	const range = doc.createRange();
	range.collapse(true);
	assert.equal(extractSelection(doc, range, adapter), null);
});

test('a selection outside any message yields nothing', () => {
	// The signal to fall back to the whole conversation, rather than saving an
	// empty file.
	const doc = load();
	const heading = doc.querySelector('h1');
	const range = doc.createRange();
	range.selectNodeContents(heading);

	assert.equal(extractSelection(doc, range, adapter), null);
});

test('a selection is reported as partial', () => {
	const doc = load();
	const range = rangeAcross(
		doc,
		'[data-message-id="m1"] p',
		0,
		'[data-message-id="m3"] p',
		1
	);
	const result = extractSelection(doc, range, adapter);
	assert.equal(result.conversation.partial, true);
});

test('a selection keeps stable keys where the page has them', () => {
	const doc = load();
	const range = rangeAcross(
		doc,
		'[data-message-id="m1"] p',
		0,
		'[data-message-id="m2"] p',
		1
	);
	const result = extractSelection(doc, range, adapter);
	assert.deepEqual(result.conversation.keys, ['m1', 'm2']);
});

test('a selection reads in thread order and keeps the messages inside it', () => {
	// Selecting m1 through m3 includes m2, because it is inside the range --
	// taking only the endpoints would silently drop content. The result is in
	// document order regardless of drag direction, so a transcript never opens
	// with the reply before the question that prompted it. A range whose end
	// precedes its start cannot be constructed in this environment, so the
	// ordering is asserted on the forward case, which has the same property.
	const doc = load();
	const range = doc.createRange();
	// Offsets into a text node, not into the element: an element offset is a
	// child-node index, and these paragraphs have exactly one child.
	range.setStart(doc.querySelector('[data-message-id="m1"] p').firstChild, 0);
	range.setEnd(doc.querySelector('[data-message-id="m3"] p').firstChild, 3);

	const result = extractSelection(doc, range, adapter);
	assert.deepEqual(result.conversation.keys, ['m1', 'm2', 'm3']);
	assert.deepEqual(result.conversation.turns.map((t) => t.role), ['user', 'assistant', 'user']);
});

test('a selection strips the copy button', () => {
	const doc = load();
	const range = rangeAcross(
		doc,
		'[data-message-id="m1"] p',
		0,
		'[data-message-id="m2"] p',
		1
	);
	const result = extractSelection(doc, range, adapter);
	const assistant = result.conversation.turns[1];
	assert.doesNotMatch(assistant.body, /Copy/, 'the copy button leaked into the selection');
	assert.match(assistant.body, /withTaskGroup/);
});

test('a selection is trusted slightly less than a full capture', () => {
	// A subset is known-correct by construction, but the user's intent about
	// the boundary is inferred, so the confidence says so.
	const doc = load();
	const range = rangeAcross(
		doc,
		'[data-message-id="m1"] p',
		0,
		'[data-message-id="m2"] p',
		1
	);
	const result = extractSelection(doc, range, adapter);
	assert.ok(result.confidence.score < 1, 'a selection claims the same confidence as a full capture');
	assert.ok(result.confidence.score >= 0.75, 'a clean selection is reported as untrustworthy');
	assert.equal(result.confidence.complete, true, 'a selection is complete as a selection');
});

test('a selection with no stable keys is reported as less reliable', () => {
	const html = `<html><head><title>t</title></head><body><main>
		<div data-testid="user-message"><p>no id here</p></div>
		<div data-testid="assistant-message"><p>nor here</p></div>
		</main></body></html>`;
	const dom = new JSDOM(html, { url: claudeURL });
	const doc = dom.window.document;
	const range = rangeAcross(
		doc,
		'[data-testid="user-message"] p',
		0,
		'[data-testid="assistant-message"] p',
		1
	);
	const result = extractSelection(doc, range, adapter);
	assert.ok(result.confidence.score < 0.75);
});

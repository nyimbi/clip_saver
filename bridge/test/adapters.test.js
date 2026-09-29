import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { test } from 'node:test';

import { JSDOM } from 'jsdom';

import { ADAPTERS, RELIABLE, adapterFor, chatgpt, claude } from '../src/adapters.js';

const here = dirname(fileURLToPath(import.meta.url));

/**
 * The fixtures are hand-written from the structure the adapters document, not
 * captured from a live page. They verify the adapters' *contract* -- role
 * mapping, key extraction, ordering, title handling, and the confidence
 * reported when the page does not match. They do not prove the selectors match
 * any real site, and a fixture written from a guess would only encode the guess.
 * That needs a real saved page.
 */
function load(name, url) {
	const html = readFileSync(join(here, 'fixtures', name), 'utf8');
	const dom = new JSDOM(html, { url });
	return dom.window.document;
}

const claudeURL = 'https://claude.ai/chat/abc123';
const chatgptURL = 'https://chatgpt.com/c/xyz789';

test('an adapter is chosen by hostname', () => {
	assert.equal(adapterFor({ hostname: 'claude.ai' })?.id, 'claude');
	assert.equal(adapterFor({ hostname: 'chatgpt.com' })?.id, 'chatgpt');
	assert.equal(adapterFor({ hostname: 'chat.openai.com' })?.id, 'chatgpt');
	assert.equal(adapterFor({ hostname: 'gemini.google.com' })?.id, 'gemini');
});

test('an unsupported page has no adapter', () => {
	assert.equal(adapterFor({ hostname: 'example.com' }), null);
	assert.equal(adapterFor({ hostname: 'notclaude.ai.evil.com' }), null);
});

test('a subdomain does not match an unrelated host', () => {
	// `endsWith('.claude.ai')` would accept `xclaude.ai` only if written
	// carelessly; the check is on the dot, so it does not.
	assert.equal(adapterFor({ hostname: 'evilanthropic.com' }), null);
});

test('a Claude conversation extracts its turns in order', () => {
	const doc = load('claude-conversation.html', claudeURL);
	const result = claude.extract(doc, new URL(claudeURL));

	assert.equal(result.ok, true, result.reason);
	assert.equal(result.conversation.turns.length, 4);
	assert.deepEqual(
		result.conversation.turns.map((t) => t.role),
		['user', 'assistant', 'user', 'assistant']
	);
});

test('a Claude conversation reports a reliable extraction', () => {
	const doc = load('claude-conversation.html', claudeURL);
	const { confidence } = claude.extract(doc, new URL(claudeURL));
	assert.equal(confidence.complete, true);
	assert.ok(confidence.score >= RELIABLE, `score ${confidence.score} below ${RELIABLE}`);
	assert.deepEqual(confidence.warnings, []);
});

test('stable keys are extracted per turn', () => {
	const doc = load('claude-conversation.html', claudeURL);
	const result = claude.extract(doc, new URL(claudeURL));
	assert.deepEqual(result.conversation.keys, ['m1', 'm2', 'm3', 'm4']);
});

test('turn order is the document order', () => {
	const doc = load('claude-conversation.html', claudeURL);
	const result = claude.extract(doc, new URL(claudeURL));
	assert.deepEqual(result.conversation.order, [0, 1, 2, 3]);
});

test('the title is taken from the heading, without a product suffix', () => {
	const doc = load('claude-conversation.html', claudeURL);
	const result = claude.extract(doc, new URL(claudeURL));
	assert.equal(result.conversation.title, 'Structured concurrency in Swift');
});

test('the document title is used when there is no heading', () => {
	const html = '<html><head><title>A Chat - ChatGPT</title></head><body><main>'
		+ '<div data-message-author-role="user" data-message-id="1">hi</div></main></body></html>';
	const dom = new JSDOM(html, { url: chatgptURL });
	const result = chatgpt.extract(dom.window.document, new URL(chatgptURL));
	assert.equal(result.conversation.title, 'A Chat');
});

test('a URL is recorded so the note can link back', () => {
	const doc = load('claude-conversation.html', claudeURL);
	const result = claude.extract(doc, new URL(claudeURL));
	assert.equal(result.conversation.url, claudeURL);
});

test('the source records which platform it came from', () => {
	const doc = load('claude-conversation.html', claudeURL);
	const result = claude.extract(doc, new URL(claudeURL));
	assert.equal(result.conversation.source, 'claude');
});

// MARK: - Content

test('code blocks keep their text and lose the surrounding chrome', () => {
	const doc = load('claude-conversation.html', claudeURL);
	const { turns } = claude.extract(doc, new URL(claudeURL)).conversation;
	const answer = turns[1].body;
	assert.match(answer, /withTaskGroup/, 'the code is missing');
	assert.doesNotMatch(answer, /Copy/, 'the copy button leaked into the turn');
});

test('a table survives as text', () => {
	const doc = load('claude-conversation.html', claudeURL);
	const { turns } = claude.extract(doc, new URL(claudeURL)).conversation;
	assert.match(turns[1].body, /Approach/);
	assert.match(turns[1].body, /async let/);
});

test('a thinking block is captured as reasoning, not as the answer', () => {
	const doc = load('claude-conversation.html', claudeURL);
	const { turns } = claude.extract(doc, new URL(claudeURL)).conversation;
	assert.match(turns[3].reasoning, /Task groups propagate/);
	assert.match(turns[3].body, /first thrown error propagates/);
});

test('reasoning is stripped of its label and display indentation', () => {
	// The `<summary>` is the block's own label, and the indentation is for
	// display. Leaving either in produces a field that reads as mangled when it
	// is quoted back in an exported transcript.
	const doc = load('claude-conversation.html', claudeURL);
	const { turns } = claude.extract(doc, new URL(claudeURL)).conversation;
	const reasoning = turns[3].reasoning;
	assert.doesNotMatch(reasoning, /Thinking/, 'the summary label leaked in');
	assert.doesNotMatch(reasoning, /\t/, 'template indentation leaked in');
	assert.equal(reasoning, reasoning.trim());
});

test('a turn with no thinking block has no reasoning field', () => {
	const doc = load('claude-conversation.html', claudeURL);
	const { turns } = claude.extract(doc, new URL(claudeURL)).conversation;
	assert.equal(turns[0].reasoning, null);
	assert.equal(turns[1].reasoning, null);
});

test('a collapsed thinking block that yields nothing is not recorded', () => {
	// A stub is worse than an absent field: it implies the model thought
	// something and the reason was captured.
	const html = '<html><head><title>t - Claude</title></head><body><main>'
		+ '<div data-testid="assistant-message" data-message-id="a1">'
		+ '<details><summary>Thinking</summary></details>'
		+ '<p>The answer.</p></div></main></body></html>';
	const dom = new JSDOM(html, { url: claudeURL });
	const result = claude.extract(dom.window.document, new URL(claudeURL));
	assert.equal(result.conversation.turns[0].reasoning, null);
	assert.match(result.conversation.turns[0].body, /The answer/);
});

// MARK: - Confidence

test('a turn with no stable key lowers the confidence and says why', () => {
	// The ChatGPT fixture has one message with no `data-message-id`. Without
	// keys the harvester can dedupe within a pass but not across passes.
	const doc = load('chatgpt-conversation.html', chatgptURL);
	const { confidence } = chatgpt.extract(doc, new URL(chatgptURL));
	assert.ok(confidence.score < RELIABLE, 'a keyless turn should not be trusted');
	assert.ok(
		confidence.warnings.some((w) => w.includes('stable identifier')),
		`expected a warning about keys, got ${JSON.stringify(confidence.warnings)}`
	);
});

test('a keyless turn still falls back to an index key', () => {
	const doc = load('chatgpt-conversation.html', chatgptURL);
	const result = chatgpt.extract(doc, new URL(chatgptURL));
	assert.equal(result.conversation.keys.length, 4);
	assert.equal(result.conversation.keys[3], 'index:3');
});

test('an unrecognised role is dropped rather than guessed at', () => {
	// A turn attributed to the wrong speaker is a corrupted transcript; a
	// missing one is at least visible.
	const html = '<html><head><title>t</title></head><body><main>'
		+ '<div data-message-author-role="user" data-message-id="1">hi</div>'
		+ '<div data-message-author-role="wizard" data-message-id="2">abracadabra</div>'
		+ '</main></body></html>';
	const dom = new JSDOM(html, { url: chatgptURL });
	const result = chatgpt.extract(dom.window.document, new URL(chatgptURL));

	assert.equal(result.conversation.turns.length, 1);
	assert.equal(result.conversation.turns[0].body, 'hi');
	assert.ok(result.confidence.warnings.some((w) => w.includes('wizard')));
	assert.ok(result.confidence.score < RELIABLE);
});

test('a page with no recognisable messages fails loudly', () => {
	// This is the case that matters most: a site changes its markup, the
	// selectors stop matching, and the adapter must say so. Returning an empty
	// conversation would produce a file that reads as a complete capture of
	// nothing.
	const doc = load('claude-relayout.html', claudeURL);
	const result = claude.extract(doc, new URL(claudeURL));

	assert.equal(result.ok, false);
	assert.match(result.reason, /No messages matched/);
	assert.equal(result.confidence.complete, false);
	assert.equal(result.confidence.score, 0);
});

test('a page with no container fails loudly', () => {
	const dom = new JSDOM('<html><body><div>nothing here</div></body></html>', { url: claudeURL });
	const adapter = { ...claude, container: '[data-nonexistent-root]' };
	const result = adapter.extract(dom.window.document, new URL(claudeURL));
	assert.equal(result.ok, false);
	assert.match(result.reason, /No container matched/);
});

test('an empty container fails rather than returning nothing', () => {
	const dom = new JSDOM('<html><body><main></main></body></html>', { url: claudeURL });
	const result = claude.extract(dom.window.document, new URL(claudeURL));
	assert.equal(result.ok, false);
	assert.equal(result.confidence.complete, false);
});

test('a malformed selector does not throw into the page', () => {
	const dom = new JSDOM('<html><body><main><div data-message-id="1">hi</div></main></body></html>', {
		url: chatgptURL,
	});
	// An unbalanced bracket is a syntax error in every engine.
	const adapter = { ...chatgpt, message: '[data-testid="broken' };
	const result = adapter.extract(dom.window.document, new URL(chatgptURL));
	assert.equal(result.ok, false);
});

// MARK: - Registry

test('every adapter declares the fields extraction depends on', () => {
	// A missing field here fails at the page, on someone's conversation, rather
	// than in a test.
	for (const adapter of ADAPTERS) {
		for (const field of ['id', 'displayName', 'hostnames', 'container', 'message', 'roleMap']) {
			assert.ok(adapter[field], `${adapter.id} is missing ${field}`);
		}
		assert.ok(Array.isArray(adapter.hostnames) && adapter.hostnames.length > 0);
		assert.ok(['windowed', 'infinite'].includes(adapter.kind), `${adapter.id} has kind "${adapter.kind}"`);
		assert.ok(Object.keys(adapter.roleMap).length > 0, `${adapter.id} has an empty roleMap`);
	}
});

test('every roleMap value is a role the app understands', () => {
	for (const adapter of ADAPTERS) {
		for (const [pageValue, mapped] of Object.entries(adapter.roleMap)) {
			assert.ok(
				['user', 'assistant', 'reasoning'].includes(mapped),
				`${adapter.id} maps "${pageValue}" to unknown role "${mapped}"`,
			);
		}
	}
});

#!/usr/bin/env node
/**
 * Checks the adapters against a real saved page.
 *
 * Why this exists: the fixtures in `test/fixtures/` are hand-written from the
 * structure the adapters *document*, so they verify the adapters' contract and
 * nothing about whether those selectors match anyone's current markup. Fetching
 * a logged-out page does not settle it either -- there is no conversation in the
 * HTML to match, so every selector comes back empty whether it is right or
 * wrong. Only a saved page from a real, signed-in conversation can.
 *
 * So: save the page, run this, and it tells you which adapter matched, how many
 * turns it found, and what confidence it reported.
 *
 *   node bridge/verify-page.js saved.html https://claude.ai/chat/abc123
 *
 * Add `--write-fixture` to emit a normalised, maskable fixture for committing.
 * Review the output before committing it: a saved conversation is private.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';

import { JSDOM } from 'jsdom';

import { RELIABLE, adapterFor } from './src/adapters.js';

const args = process.argv.slice(2);
const writeFixture = args.includes('--write-fixture');
const positional = args.filter((a) => !a.startsWith('--'));

const [file, pageURL] = positional;

if (!file || !pageURL) {
	console.error('usage: node bridge/verify-page.js <saved.html> <url> [--write-fixture]');
	process.exit(2);
}

const html = readFileSync(file, 'utf8');
const dom = new JSDOM(html, { url: pageURL });
const doc = dom.window.document;

const adapter = adapterFor(new URL(pageURL));
if (!adapter) {
	console.error(`No adapter recognises ${new URL(pageURL).hostname}.`);
	console.error('Supported:', ['claude.ai', 'chatgpt.com', 'gemini.google.com'].join(', '));
	process.exit(1);
}

console.log(`file    ${basename(file)}  (${html.length.toLocaleString()} bytes)`);
console.log(`url     ${pageURL}`);
console.log(`adapter ${adapter.id} — ${adapter.displayName}  (${adapter.kind})`);
console.log('');
console.log(`  container  ${adapter.container}`);
console.log(`  message    ${adapter.message}`);
console.log(`  role       ${adapter.role}`);
console.log(`  key        ${adapter.keyAttribute}`);
console.log('');

const containerFound = doc.querySelector(adapter.container);
const messageCount = containerFound
	? containerFound.querySelectorAll(adapter.message).length
	: 0;

console.log(`  container matched   ${containerFound ? 'yes' : 'NO'}`);
console.log(`  message nodes found ${messageCount}`);
console.log('');

if (!containerFound || messageCount === 0) {
	console.log('VERDICT  selectors do not match this page.');
	console.log('');
	console.log('This is the interesting outcome. To find the real markup:');
	console.log('  1. Open a conversation, scroll so several exchanges are visible.');
	console.log('  2. DevTools -> select an element -> copy its outerHTML.');
	console.log('  3. Look for the role marker and a stable id per message.');
	console.log('  4. Update the adapter, then re-run this.');
	process.exit(1);
}

const result = adapter.extract(doc, new URL(pageURL));
if (!result.ok) {
	console.log(`VERDICT  extraction refused: ${result.reason}`);
	process.exit(1);
}

const { conversation, confidence } = result;
const roles = conversation.turns.reduce((counts, t) => {
	counts[t.role] = (counts[t.role] ?? 0) + 1;
	return counts;
}, {});

console.log(`  turns extracted     ${conversation.turns.length}`);
console.log(`  roles               ${Object.entries(roles).map(([r, n]) => `${r}×${n}`).join('  ')}`);
console.log(`  stable keys         ${conversation.keys.filter((k) => !k.startsWith('index:')).length}/${conversation.turns.length}`);
console.log(`  title               ${conversation.title ?? '(none)'}`);
console.log(`  confidence          ${confidence.score.toFixed(2)}  ${confidence.score >= RELIABLE ? '(reliable)' : '(BELOW THRESHOLD)'}`);
console.log('');

if (confidence.warnings.length) {
	console.log('  warnings');
	for (const warning of confidence.warnings) console.log(`    - ${warning}`);
	console.log('');
}

if (conversation.keys.some((k) => k.startsWith('index:'))) {
	console.log('  Some turns fell back to a positional key. On a long conversation');
	console.log('  the harvester cannot deduplicate those across scroll steps, so turns');
	console.log('  may be duplicated. If the page exposes a real id, use it.');
	console.log('');
}

const firstTurn = conversation.turns[0]?.body ?? '';
console.log(`  first turn, first line: ${firstTurn.split('\n')[0].slice(0, 70)}`);
console.log('');

if (writeFixture) {
	const out = basename(file).replace(/\.html?$/i, '') || 'page';
	const target = `bridge/test/fixtures/${out}.html`;
	writeFileSync(target, html);
	console.log(`  fixture written to ${target}`);
	console.log('  REVIEW IT BEFORE COMMITTING — a saved conversation is private.');
}

console.log(confidence.score >= RELIABLE ? 'VERDICT  selectors match this page.' : 'VERDICT  partial match — see the warnings above.');

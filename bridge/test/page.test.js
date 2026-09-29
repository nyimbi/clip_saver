import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { JSDOM } from 'jsdom';

import { extractPage, findContent } from '../src/page.js';

const here = dirname(fileURLToPath(import.meta.url));

/**
 * Readability extraction, for pages that are not a conversation.
 *
 * The failure this guards against is specific and ugly: a confident file full
 * of navigation, cookie banners and "related posts" that looks like a saved
 * article and is actually a sitemap with prose. So the assertions are about
 * what is *absent* as much as what is present, and about the score being
 * reported rather than implied.
 */

function load(name = 'article.html', url = 'https://example.com/blog/structured-concurrency') {
	const html = readFileSync(join(here, 'fixtures', name), 'utf8');
	return new JSDOM(html, { url }).window.document;
}

const has = (doc, fragment) => doc.body.innerHTML.includes(fragment);

test('the article is found rather than the page', () => {
	const doc = load();
	const found = findContent(doc);
	assert.ok(found, 'no content region found at all');
	assert.ok(found.score >= 0.6, `score ${found.score} is too low to trust`);
});

test('the extracted region is the article, not the page', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/blog/structured-concurrency'));
	assert.equal(result.ok, true);
	assert.match(result.html, /Structured concurrency means/);
	assert.match(result.html, /withTaskGroup/);
});

// MARK: - What must not be in the output

test('navigation is not in the output', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/'));
	assert.doesNotMatch(result.html, /site-nav/);
	assert.doesNotMatch(result.html, /Pricing/);
});

test('the cookie banner is not in the output', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/'));
	assert.doesNotMatch(result.html, /cookie-consent/);
	assert.doesNotMatch(result.html, /Accept all/);
});

test('the newsletter prompt is not in the output', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/'));
	assert.doesNotMatch(result.html, /newsletter/);
	assert.doesNotMatch(result.html, /Subscribe/);
});

test('the related-links rail is not in the output', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/'));
	assert.doesNotMatch(result.html, /related-posts/);
	assert.doesNotMatch(result.html, /Actors and isolation/);
});

test('the footer is not in the output', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/'));
	assert.doesNotMatch(result.html, /Example Dev Blog<\/p>/);
});

// MARK: - What must survive

test('code blocks survive', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/'));
	assert.match(result.html, /language-swift/);
	assert.match(result.html, /group\.addTask/);
});

test('tables survive', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/'));
	assert.match(result.html, /<table/);
	assert.match(result.html, /Task group/);
});

test('headings survive', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/'));
	assert.match(result.html, /Understanding structured concurrency/);
});

// MARK: - Title

test('the title is taken from the heading', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/'));
	assert.equal(result.title, 'Understanding structured concurrency');
});

test('a site suffix is stripped from the document title', () => {
	const dom = new JSDOM('<html><head><title>An Article — Example Site</title></head><body><main><p>text</p></main></body></html>', {
		url: 'https://example.com/',
	});
	const result = extractPage(dom.window.document, new URL('https://example.com/'));
	assert.equal(result.title, 'An Article');
});

// MARK: - Confidence

test('a clean article is reported as reliable', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/'));
	assert.ok(result.confidence.score >= 0.6);
	assert.equal(result.confidence.complete, true);
	assert.deepEqual(result.confidence.warnings, []);
});

/// A page that is mostly links is not an article, and saying so is the whole
/// point of scoring it.
test('a navigation-only page scores badly and says so', () => {
	const dom = new JSDOM(`<html><head><title>Nav</title></head><body><div class="menu">
		${Array.from({ length: 40 }, (_, i) => `<a href="/p${i}">Page number ${i} of the site index</a>`).join(' ')}
		</div></body></html>`, { url: 'https://example.com/' });
	const result = extractPage(dom.window.document, new URL('https://example.com/'));
	assert.ok(
		result.confidence.score < 0.6 || result.confidence.warnings.length > 0,
		'a page of links was reported as reliable content',
	);
});

test('a very short page is flagged', () => {
	const dom = new JSDOM('<html><head><title>t</title></head><body><main><p>Hi.</p></main></body></html>', {
		url: 'https://example.com/',
	});
	const result = extractPage(dom.window.document, new URL('https://example.com/'));
	assert.ok(
		result.confidence.warnings.some((w) => /short/i.test(w)),
		'a one-sentence page was not flagged as possibly a stub',
	);
});

test('an empty page fails rather than producing an empty file', () => {
	const dom = new JSDOM('<html><head><title>Empty</title></head><body></body></html>', {
		url: 'https://example.com/',
	});
	const result = extractPage(dom.window.document, new URL('https://example.com/'));
	assert.equal(result.ok, false);
	assert.equal(result.confidence.complete, false);
	assert.match(result.reason, /No article-like region/);
});

test('a page with no heading falls back to the hostname', () => {
	const dom = new JSDOM('<html><head><title></title></head><body><main><p>Some text here.</p></main></body></html>', {
		url: 'https://example.com/page',
	});
	const result = extractPage(dom.window.document, new URL('https://example.com/page'));
	assert.equal(result.title, 'example.com');
});

// MARK: - Shape

/// A page has no roles, so it becomes one assistant turn rather than being
/// forced into a shape it does not have. The same file, frontmatter and archive
/// then apply to an article as to a conversation.
test('a page is represented as a single turn', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/'));
	assert.equal(result.conversation.turns.length, 1);
	assert.equal(result.conversation.turns[0].role, 'assistant');
	assert.equal(result.conversation.source, 'web');
	assert.equal(result.conversation.partial, false);
});

test('the url is recorded so the note links back', () => {
	const doc = load();
	const result = extractPage(doc, new URL('https://example.com/blog/x'));
	assert.equal(result.conversation.url, 'https://example.com/blog/x');
});

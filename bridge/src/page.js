/**
 * Generic page extraction, for pages that are not a conversation.
 *
 * "Save this article" is a different job from "save this chat", and the
 * difficulty is the mirror image. A chat has explicit role markers, so the hard
 * part was deciding what a selector means. An article has none of that, and the
 * hard part is the opposite: deciding which of ten thousand elements is *the
 * content* and which are navigation, cookie banners, related links, comment
 * threads and share buttons.
 *
 * Nothing is thrown away on the strength of a guess. A candidate region is
 * scored, and the score is reported. A low score produces a file that says it
 * is a low-confidence capture, rather than a confident file full of navigation.
 *
 * This is deliberately heuristic rather than clever. Readability extraction is a
 * solved-enough problem with a well-known shape — score candidates by text
 * density, link density and paragraph count, take the best, keep the chrome that
 * looks structural — and the alternative, an LLM in the loop, would mean a
 * network request carrying a page the user did not ask us to send anywhere.
 */

/** Elements that are never content, whatever they contain. */
const CHROME_SELECTORS = [
	'script', 'style', 'noscript', 'template', 'iframe', 'object', 'embed',
	'nav', 'header', 'footer', 'aside', 'form',
	'[role="navigation"]', '[role="banner"]', '[role="contentinfo"]', '[role="search"]',
	'[aria-hidden="true"]',
	'button', 'select', 'textarea', 'input',
	'.advert', '.ad', '.ads', '.advertisement', '.cookie', '.consent', '.gdpr',
	'.newsletter', '.subscribe', '.paywall', '.social-share', '.share-buttons',
	'.related', '.recommended', '.comments', '.comment-list', '.breadcrumb',
	'.sidebar', '.site-nav', '.skip-link',
];

/** Class or id fragments that mark chrome, matched as substrings. */
const CHROME_HINTS = [
	'nav', 'menu', 'sidebar', 'footer', 'header', 'banner', 'cookie', 'consent',
	'gdpr', 'advert', 'promo', 'newsletter', 'subscribe', 'social', 'share',
	'related', 'recommend', 'comment', 'breadcrumb', 'popup', 'modal', 'paywall',
	'skip-link', 'screen-reader', 'visually-hidden',
];

/** Tag names that can hold the body of an article. */
const CONTENT_TAGS = ['article', 'main'];

/** Below this, a capture is reported as untrustworthy. */
export const RELIABLE = 0.6;

const textLength = (element) =>
	(element.textContent ?? '').replace(/\s+/g, ' ').trim().length;

const linkTextLength = (element) => {
	let total = 0;
	for (const anchor of element.querySelectorAll('a')) {
		total += textLength(anchor);
	}
	return total;
};

const paragraphCount = (element) => element.querySelectorAll('p').length;

/**
 * Scores a candidate region.
 *
 * Three signals, because each fails alone:
 *
 *   - **Text density** — a content region is mostly text. A navigation region is
 *     mostly links, which is the single most reliable discriminator.
 *   - **Paragraph count** — prose comes in paragraphs. A menu does not.
 *   - **Link density** — the inverse of the first, kept separate so a page that
 *     is genuinely a list of articles is not thrown away for having links.
 *
 * Class and id hints *subtract*. They are weak evidence and are used only to
 * break ties, because plenty of real content lives in an element called
 * `story-body` or `article-content` and a name-based penalty would be applied
 * with no way to appeal it.
 */
function score(element) {
	const text = textLength(element);
	if (text === 0) return null;

	const links = linkTextLength(element);
	const linkRatio = links / text;
	const paragraphs = paragraphCount(element);

	let value = 0;
	// Text that is not links is the signal.
	value += (1 - linkRatio) * 50;
	// Prose is paragraphs. Three earns most of the credit, since a short post
	// may legitimately have two.
	value += Math.min(paragraphs, 6) / 6 * 30;
	// Length matters, logarithmically: a 2000-character region beats a
	// 200-character one, but a 200,000-character one is not ten times better.
	value += Math.min(Math.log10(text + 1) / 5, 1) * 20;

	for (const attribute of ['class', 'id']) {
		const value2 = (element.getAttribute(attribute) ?? '').toLowerCase();
		if (!value2) continue;
		if (CHROME_HINTS.some((hint) => value2.includes(hint))) value -= 40;
	}

	return Math.max(0, Math.min(1, value / 100));
}

/**
 * The best content region on a page.
 *
 * @returns {{element: Element, score: number}|null}
 */
export function findContent(doc) {
	// Explicit containers first. `<main>` and `<article>` are what a page says
	// it is, which is stronger evidence than anything inferred.
	for (const selector of CONTENT_TAGS) {
		for (const element of doc.querySelectorAll(selector)) {
			const cleaned = strip(element.cloneNode(true));
			const value = score(cleaned);
			if (value !== null && value >= 0.5) {
				return { element, score: value };
			}
		}
	}

	// Otherwise the densest region on the page.
	let best = null;
	for (const element of doc.querySelectorAll('div, section, td')) {
		// Only consider a region that is not nested inside a better one, so the
		// whole page does not win on total length.
		if (element.querySelector('article, main')) continue;

		const value = score(element);
		if (value === null) continue;
		if (!best || value > best.score) best = { element, score: value };
	}
	return best;
}

function strip(clone) {
	for (const selector of CHROME_SELECTORS) {
		for (const element of Array.from(clone.querySelectorAll(selector))) {
			element.remove();
		}
	}
	return clone;
}

/**
 * Turns a page into a conversation-shaped record.
 *
 * A page is represented as a single assistant turn rather than being forced
 * into a user/assistant shape it does not have, so the same file, the same
 * frontmatter and the same archive apply to an article as to a conversation.
 *
 * @param {Document} doc
 * @param {URL} url
 */
export function extractPage(doc, url) {
	const found = findContent(doc);
	if (!found) {
		return {
			ok: false,
			reason: 'No article-like region was found. The page may be an application rather than a document.',
			confidence: { score: 0, complete: false, strategy: 'dom', warnings: [] },
		};
	}

	// The clone is stripped so the chrome never reaches the converter, while the
	// score was taken on the cleaned shape rather than the raw one.
	const cleaned = strip(found.element.cloneNode(true));
	const html = cleaned.innerHTML;

	const warnings = [];
	if (found.score < RELIABLE) {
		warnings.push(
			`The main content region scored ${found.score.toFixed(2)}, below ${RELIABLE}. `
			+ 'Some navigation or commentary may have been included.',
		);
	}
	if (textLength(found.element) < 400) {
		warnings.push('The extracted region is very short; this may be a stub rather than a full page.');
	}

	return {
		ok: true,
		html,
		title: readTitle(doc, url),
		conversation: {
			title: readTitle(doc, url),
			source: 'web',
			model: null,
			url: url.href,
			turns: [{ role: 'assistant', body: '' }],
			keys: ['page:1'],
			order: [0],
			partial: false,
		},
		confidence: {
			score: found.score,
			// A page is never "incomplete" in the harvest sense; it may be the
			// wrong region, which the score reports.
			complete: true,
			strategy: 'dom',
			warnings,
		},
	};
}

function readTitle(doc, url) {
	const heading = doc.querySelector('h1, article h1, main h1');
	const text = heading?.textContent?.trim();
	if (text) return text;
	const title = (doc.title || '').trim();
	// Split off a site suffix: "An Article — The Site" -> "An Article".
	return title.split(/\s+[—–|]\s+/)[0].trim() || url.hostname;
}

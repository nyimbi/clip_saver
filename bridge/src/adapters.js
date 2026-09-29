/**
 * Per-platform extraction adapters.
 *
 * Each adapter answers one question: given the page as it is right now, what is
 * the conversation? Everything structural -- conversion to Markdown, frontmatter,
 * fingerprinting, incremental save, the archive -- happens in the native app.
 * The adapter's only job is to produce a faithful `Conversation` or to say
 * honestly that it could not.
 *
 * The contract an adapter must honour:
 *
 *   1. Return a confidence. A conversation that was cut short must say so. A file
 *      that silently lost most of its turns reads as a backup and is not one.
 *   2. Never invent turns. If the selectors do not match, the answer is a
 *      failure, not an empty conversation.
 *   3. Keys must be stable across harvests. The harvester dedupes on them, and a
 *      key derived from text changes under a streaming message.
 *   4. Turn order must be the document order of the conversation, since the
 *      harvester may discover turns out of order.
 *
 * The selectors are the fragile part, and they are isolated here so that a site
 * change is one file to fix rather than a rewrite.
 */

/** Confidence below which a capture is not trusted to be complete. */
export const RELIABLE = 0.75;

/** @typedef {{score: number, complete: boolean, strategy: string, warnings: string[]}} Confidence */

const complete = (score = 1, strategy = 'dom', warnings = []) => ({
	score,
	complete: true,
	strategy,
	warnings,
});

const incomplete = (score, reason, strategy = 'dom') => ({
	score,
	complete: false,
	strategy,
	warnings: [reason],
});

/**
 * A generic adapter described by selectors.
 *
 * Built by declaration rather than written per site, so a new platform is a data
 * change. `messageSelector` finds turns; `roleAttribute` or `roleSelector`
 * identifies who spoke; `keyAttribute` gives the stable identity.
 */
export function defineAdapter({
	id,
	displayName,
	hostnames,
	kind = 'windowed',
	container,
	message,
	role,
	/**
	 * Attribute holding a turn's stable identity, e.g. `data-message-id`.
	 *
	 * Distinct from the role *selector*. The two were conflated in the first
	 * version, and the Claude adapter -- whose key selector was `[data-testid]`
	 * -- then produced the same key for every turn of a given role, so a
	 * four-turn conversation deduped down to two. A harvester keyed that way
	 * silently drops half a transcript, which is why the attribute is named
	 * rather than derived from a selector.
	 */
	keyAttribute = 'data-message-id',
	model,
	title,
	/** Turn roles keyed by the value found in the page. */
	roleMap = { user: 'user', human: 'user', assistant: 'assistant', ai: 'assistant' },
	/** Selectors that are stripped before a turn is read. */
	strip = ['script', 'style', 'button', '[role="button"]', '[data-testid="copy-button"]'],
}) {
	return {
		id,
		displayName,
		hostnames,
		kind,
		container,
		message,
		role,
		keyAttribute,
		model,
		title,
		roleMap,
		strip,

		/**
		 * Whether this adapter recognises the page it is looking at.
		 * @param {Location} location
		 */
		matches(location) {
			return this.hostnames.some((h) => location.hostname === h || location.hostname.endsWith(`.${h}`));
		},

		/**
		 * Reads the conversation from a document.
		 *
		 * Takes the document rather than reaching for a global, so the whole
		 * adapter is testable against fixture markup with no browser.
		 *
		 * @param {Document} doc
		 * @param {URL} url
		 */
		extract(doc, url) {
			const containerElement = css(doc, this.container);
			if (!containerElement) {
				return failure(`No container matched on this page. The site layout has probably changed.`);
			}

			const nodes = Array.from(containerElement.querySelectorAll(this.message));
			if (nodes.length === 0) {
				return failure(
					`No messages matched "${this.message}". The site layout has probably changed.`
				);
			}

			const turns = [];
			const warnings = [];
			let matchedRole = 0;
			let matchedKey = 0;

			nodes.forEach((node, index) => {
				const roleValue = attribute(node, this.role);
				const mapped = this.roleMap[roleValue];
				if (!mapped) {
					// An unmapped role is dropped rather than guessed. A turn
					// attributed to the wrong speaker is a corrupted transcript,
					// and a missing one is at least visible.
					warnings.push(`Turn ${index + 1} had an unrecognised role "${roleValue ?? "none"}" and was skipped.`);
					return;
				}
				matchedRole += 1;

				// The identity attribute, read directly rather than through a
				// selector: a turn's stable key is an attribute *value*, and
				// routing it through a selector risks reading the role attribute
				// by mistake.
				const stableKey = this.keyAttribute ? node.getAttribute?.(this.keyAttribute) ?? null : null;
				if (stableKey) matchedKey += 1;

				// The key falls back to the node's index, which is stable only
				// within a single harvest. That is enough to dedupe within a pass
				// and is recorded in the confidence below, because it is not
				// enough to dedupe across one.
				turns.push({
					role: mapped,
					body: readTurn(node, this.strip),
					key: stableKey ?? `index:${index}`,
					reasoning: readReasoning(node),
					toolCalls: readToolCalls(node),
				});
			});

			if (turns.length === 0) {
				return failure('Every message was dropped: no role could be identified.');
			}

			// Confidence reflects what the adapter could actually verify, not how
			// well the page happened to look.
			let score = 1;
			if (matchedRole < nodes.length) {
				score -= 0.2;
				warnings.push(`${nodes.length - matchedRole} of ${nodes.length} messages had no recognisable role.`);
			}
			if (matchedKey < nodes.length) {
				// Without stable keys the harvester can dedupe within one pass but
				// not across passes, so a long walk may duplicate turns and the
				// transcript cannot be trusted to be a faithful sequence. The
				// penalty has to cross the reliability threshold on its own: a
				// capture whose ordering is unverifiable is not reliable however
				// well everything else went.
				score -= 0.3;
				warnings.push(
					'Messages carry no stable identifier, so a long conversation may be captured with duplicates.'
				);
			}

			return {
				ok: true,
				conversation: {
					title: this.readTitle(doc, url),
					source: this.id,
					model: this.model ? attribute(doc.documentElement, this.model) : null,
					url: url.href,
					turns: turns.map(({ key, ...rest }) => rest),
					keys: turns.map((t) => t.key),
					order: turns.map((_, index) => index),
				},
				confidence: complete(score, this.kind === 'windowed' ? 'dom' : 'dom', warnings),
			};
		},

		readTitle(doc, url) {
			if (this.title) {
				const element = css(doc, this.title);
				if (element) {
					const text = element.textContent?.trim();
					if (text) return text;
				}
			}
			// Every SPA renders the document title with a product suffix, so the
			// suffix is stripped rather than ending up in the filename.
			return (doc.title || url.hostname).replace(/\s*[-–—|]\s*(Claude|ChatGPT|Gemini).*$/i, '').trim();
		},
	};
}

function failure(reason) {
	return { ok: false, reason, confidence: incomplete(0, reason) };
}

function css(doc, selector) {
	try {
		return doc.querySelector(selector);
	} catch {
		// A malformed selector in an adapter should not throw into the page.
		return null;
	}
}

/**
 * The value of `selector` for a node, whether the node is itself the match or
 * contains one.
 *
 * The important part is how the value is read. The node's own attributes are
 * consulted first, and the *selector's own attribute name* is not guessed: a
 * selector like `[data-testid^="user-message"]` carries its value in
 * `data-testid`, while `[data-message-author-role]` carries it in
 * `data-message-author-role`. Reading a fixed list of attribute names -- which
 * is what the first version did, looking only at `data-role` and `role` -- gets
 * `null` for every one of them, and the adapter then drops every turn and
 * reports "no role could be identified".
 *
 * So the attribute name is taken from the selector, with the matching prefix
 * stripped.
 *
 * @param {Element} node
 * @param {string} selector
 */
function attribute(node, selector) {
	if (!selector || !node) return null;
	try {
		// A compound or attribute-bearing selector may carry its value on the
		// node or on a descendant; try the node first, then a descendant.
		const found = node.matches?.(selector) ? node : node.querySelector?.(selector);
		if (!found) return null;

		const attributeName = valueAttributeIn(selector);
		if (attributeName) {
			const value = found.getAttribute?.(attributeName);
			if (value) return value;
		}
		// No identifiable attribute, so fall back to the usual carriers.
		return found.getAttribute?.('data-role') ?? found.getAttribute?.('role') ?? null;
	} catch {
		// A malformed selector in an adapter should not throw into the page.
		return null;
	}
}

/** The attribute a selector reads, e.g. `[data-testid^=x]` -> `data-testid`. */
function valueAttributeIn(selector) {
	const match = /\[([a-zA-Z-]+)(?:[\^$*~|]?=)?/.exec(selector);
	return match ? match[1] : null;
}

/** Text of one turn, with chrome removed. */
function readTurn(node, strip) {
	const clone = node.cloneNode(true);
	for (const selector of strip) {
		for (const element of Array.from(clone.querySelectorAll(selector))) {
			element.remove();
		}
	}
	return (clone.textContent ?? '').replace(/\u00a0/g, ' ').replace(/[ \t]+\n/g, '\n').trim();
}

/**
 * A thinking or reasoning block, cleaned up.
 *
 * The label ("Thinking", "Reasoning") is the `<summary>` and is dropped, as is
 * the template whitespace: these blocks are indented for display and that
 * indentation is not part of what the model said. Leaving it in produces a
 * reasoning field that reads as mangled when it is quoted back in an
 * exported transcript.
 */
function readReasoning(node) {
	const element = node.querySelector?.('details, [data-testid*="thinking" i], [class*="thinking" i]');
	if (!element) return null;

	const clone = element.cloneNode(true);
	for (const summary of Array.from(clone.querySelectorAll('summary'))) {
		summary.remove();
	}
	const text = (clone.textContent ?? '')
		.split('\n')
		.map((line) => line.replace(/[ \t]+/g, ' ').trim())
		.filter(Boolean)
		.join('\n')
		.trim();

	// A collapsed block that yields only whitespace carries nothing worth
	// keeping, and a stub is worse than an absent field.
	return text.length >= 20 ? text : null;
}

function readToolCalls(node) {
	const calls = [];
	for (const element of node.querySelectorAll?.('[data-testid*="tool" i], [class*="tool-call" i]') ?? []) {
		const name = element.getAttribute?.('data-tool') ?? element.getAttribute?.('data-testid');
		if (!name) continue;
		calls.push({ name, input: null, output: element.textContent?.trim() ?? null });
	}
	return calls;
}

// MARK: - Platforms

/**
 * Claude. Roles are carried in `data-testid` attributes rather than a role
 * attribute, which is why the adapter matches on those.
 */
export const claude = defineAdapter({
	id: 'claude',
	displayName: 'Claude',
	hostnames: ['claude.ai'],
	kind: 'windowed',
	container: 'main, [role="main"], body',
	message: '[data-testid^="user-message"], [data-testid^="assistant-message"]',
	role: '[data-testid^="user-message"], [data-testid^="assistant-message"]',
	keyAttribute: 'data-message-id',
	model: '[data-testid="model-name"]',
	title: 'h1',
	roleMap: {
		'user-message': 'user',
		'assistant-message': 'assistant',
	},
});

/**
 * ChatGPT. `data-message-author-role` is the attribute the DOM has exposed
 * consistently; the turn identity is its `data-message-id`.
 */
export const chatgpt = defineAdapter({
	id: 'chatgpt',
	displayName: 'ChatGPT',
	hostnames: ['chatgpt.com', 'chat.openai.com'],
	kind: 'windowed',
	container: 'main, [role="main"], body',
	message: '[data-message-author-role]',
	role: '[data-message-author-role]',
	keyAttribute: 'data-message-id',
	title: 'h1',
	roleMap: {
		user: 'user',
		assistant: 'assistant',
		system: 'user',
		tool: 'user',
	},
});

/** Gemini. */
export const gemini = defineAdapter({
	id: 'gemini',
	displayName: 'Gemini',
	hostnames: ['gemini.google.com'],
	// Gemini's list accumulates rather than evicting, so it needs the re-arming
	// harvest rather than the windowed one.
	kind: 'infinite',
	container: 'main, [role="main"], body',
	message: '[data-message-id], .conversation-turn, user-query, model-response',
	role: '[data-message-id], .conversation-turn, user-query, model-response',
	keyAttribute: 'data-message-id',
	title: 'h1',
	roleMap: {
		user: 'user',
		'user-query': 'user',
		model: 'assistant',
		'model-response': 'assistant',
	},
});

/** Every adapter, in priority order. */
export const ADAPTERS = [claude, chatgpt, gemini];

/**
 * The adapter for a page, or `null` when none recognises it.
 * @param {Location} location
 */
export function adapterFor(location) {
	return ADAPTERS.find((a) => a.matches(location)) ?? null;
}

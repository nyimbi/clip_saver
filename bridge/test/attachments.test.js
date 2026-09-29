import assert from 'node:assert/strict';
import { test } from 'node:test';

import { JSDOM } from 'jsdom';

import { extractSelection } from '../src/extract.js';

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

function turn(body) {
	return `<div data-testid="assistant-message" data-message-id="m1">${body}</div>`;
}

/** Wraps a single assistant turn and selects all of it. */
function attachmentsIn(body) {
	const html = `<!doctype html><html><body><main>${turn(body)}</main></body></html>`;
	const dom = new JSDOM(html, { url: 'https://claude.ai/chat/abc' });
	const doc = dom.window.document;
	const node = doc.querySelector('[data-testid="assistant-message"]');
	const range = doc.createRange();
	range.selectNodeContents(node);

	const result = extractSelection(doc, range, adapter);
	assert.ok(result, 'the selection produced nothing');
	return result.conversation.turns[0].attachments ?? [];
}

test('a named file becomes a reference with a size', () => {
	const attachments = attachmentsIn(
		'<p>Attached.</p><div class="attachment" data-file-name="report.pdf">report.pdf 1.2 MB</div>'
	);
	assert.equal(attachments.length, 1);

	const [report] = attachments;
	assert.equal(report.name, 'report.pdf');
	assert.equal(report.byteSize, 1_200_000);
	assert.equal(report.inline, false);
});

/** The extension-to-kind table lives in the app, which is the only place it
 * has to be right. A second copy here would be one more thing to drift. */
test('the kind is left to the app rather than guessed twice', () => {
	assert.equal(attachmentsIn('<div class="attachment" data-file-name="report.pdf">x</div>')[0].kind, null);
});

/** A generated image is already in the page, so there is nothing to download
 * and saying otherwise would be a dead link. */
test('a generated image is inline, not a download', () => {
	const [plot] = attachmentsIn(
		'<img src="data:image/png;base64,iVBORw0KGgo=" alt="plot">'
	);
	assert.equal(plot.name, 'plot');
	assert.equal(plot.inline, true);
	assert.equal(plot.url, null);
});

/** A thumbnail and its full-size twin on one card are one file to the reader. */
test('a thumbnail and its full image count once', () => {
	const attachments = attachmentsIn(`
		<div class="attachment" data-file-name="chart.png">chart.png</div>
		<div class="attachment" data-file-name="chart.png">chart.png</div>
	`);
	assert.equal(attachments.length, 1);
});

test('a turn with no files has no attachments', () => {
	assert.deepEqual(attachmentsIn('<p>just text</p>'), []);
});

test('a size written as 900 B is read, and a bare number is not guessed at', () => {
	assert.equal(attachmentsIn('<div class="attachment" data-file-name="a.txt">a.txt 900 B</div>')[0].byteSize, 900);
	assert.equal(attachmentsIn('<div class="attachment" data-file-name="a.txt">a.txt</div>')[0].byteSize, null);
});

/** Attachment containers are also used for layout -- a placeholder, a spinner,
 * an "Add file" button. Believing their text would fill the saved file with
 * phantom attachments, so a name has to carry an extension. */
test('a chip with no filename is not recorded', () => {
	assert.deepEqual(attachmentsIn('<div class="attachment">• • •</div>'), []);
	assert.deepEqual(attachmentsIn('<div class="attachment"><button>Add file</button></div>'), []);
});

test('a number is not a filename', () => {
	assert.deepEqual(attachmentsIn('<div class="attachment" data-file-name="3.14">x</div>'), []);
});

/** A card is chrome. Left in the body, the saved file lists "chart.png" as an
 * attachment and then says "chart.png" again in the message -- plus the
 * placeholder glyphs the card used while loading. */
test('theCardTextDoesNotAppearInTheBody', () => {
	const html = `<!doctype html><html><body><main>
		<div data-testid="assistant-message" data-message-id="m1">
			<p>Here it is.</p>
			<div class="attachment" data-file-name="chart.png">chart.png</div>
			<div class="attachment">&bull; &bull; &bull;</div>
		</div>
	</main></body></html>`;
	const dom = new JSDOM(html, { url: 'https://claude.ai/chat/abc' });
	const doc = dom.window.document;
	const range = doc.createRange();
	range.selectNodeContents(doc.querySelector('[data-testid="assistant-message"]'));
	const turn = extractSelection(doc, range, adapter).conversation.turns[0];

	assert.equal(turn.body, 'Here it is.');
	assert.equal(turn.attachments.length, 1);
	assert.equal(turn.attachments[0].name, 'chart.png');
});

/** The selection path used to build its turns without the shared readers, so
 * selecting a message silently dropped its reasoning, tool calls and
 * attachments. The saved file looked complete and was not, which is worse than
 * one that visibly lacks them. */
test('a selection keeps the reasoning and files the full harvest would keep', () => {
	const attachments = attachmentsIn(
		'<p>Done.</p><div class="attachment" data-file-name="out.csv">out.csv</div>'
	);
	assert.equal(attachments.length, 1, 'the selection dropped the attachment');
	assert.equal(attachments[0].name, 'out.csv');
});

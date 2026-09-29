/**
 * The whole path, once: extension source -> native framing -> compiled host ->
 * the file the user opens.
 *
 * Written because the layers below it each had tests that passed while the
 * binary they were testing could not be built. The Swift tests build through
 * Xcode, which globs the app directory; the JavaScript tests never see Swift; and
 * the host's own source list was a hand-maintained copy that had drifted by
 * seven files. Nothing crossed the boundary until something did it explicitly.
 *
 * The payload is not transcribed -- it comes out of the real extractor, so this
 * cannot drift from what the extension actually sends.
 *
 *   node e2e-host.mjs <destination> [--print]
 */
import { spawn } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { JSDOM } from 'jsdom';

import { extractSelection } from './src/extract.js';

const here = dirname(fileURLToPath(import.meta.url));
// The first argument that names an existing file is the binary; anything else
// positional is the destination, and flags are ignored. Picking wrong here means
// silently testing a stale build, which is worse than failing outright.
const positionals = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const hostBinary = positionals.find((a) => existsSync(a) && !a.endsWith('/')) ?? join(here, 'host', 'build', 'clipboard-saver-host');
const destinationArg = positionals.find((a) => a !== hostBinary);

/** The Claude adapter, as the content script sends it across the boundary. */
const adapter = {
	id: 'claude',
	kind: 'windowed',
	container: 'main',
	message: '[data-testid^="user-message"], [data-testid^="assistant-message"]',
	role: '[data-testid^="user-message"], [data-testid^="assistant-message"]',
	keyAttribute: 'data-message-id',
	roleMap: { 'user-message': 'user', 'assistant-message': 'assistant' },
	strip: ['button'],
};

const PAGE = `<!doctype html><html><head><title>Quarterly numbers</title></head><body><main>
	<div data-testid="user-message" data-message-id="m1">Can you make the chart?</div>
	<div data-testid="assistant-message" data-message-id="m2">
		<p>Here it is.</p>
		<div class="attachment" data-file-name="chart.png">chart.png 4.1 KB</div>
		<div class="attachment" data-file-name="notes.md">notes.md 812 B</div>
		<div class="attachment">&bull; &bull; &bull;</div>
	</div>
</main></body></html>`;

function conversationFromPage() {
	const dom = new JSDOM(PAGE, { url: 'https://claude.ai/chat/abc' });
	const doc = dom.window.document;
	const range = doc.createRange();
	range.selectNodeContents(doc.querySelector('main'));
	const result = extractSelection(doc, range, adapter);
	if (!result) throw new Error('the extractor produced nothing');
	// The one field the app does not read from the DOM.
	return { ...result.conversation, extractedAt: new Date().toISOString() };
}

/** Frames a request the way the native-messaging transport expects. */
function frame(request) {
	const body = Buffer.from(JSON.stringify(request), 'utf8');
	const out = Buffer.alloc(4 + body.length);
	out.writeUInt32LE(body.length, 0);
	body.copy(out, 4);
	return out;
}

/** Reads the host's framed responses. */
function readResponses(stream) {
	return new Promise((resolve) => {
		const seen = [];
		let buffer = Buffer.alloc(0);
		stream.on('data', (chunk) => {
			buffer = Buffer.concat([buffer, chunk]);
			while (buffer.length >= 4) {
				const length = buffer.readUInt32LE(0);
				if (buffer.length < 4 + length) break;
				seen.push(JSON.parse(buffer.subarray(4, 4 + length).toString('utf8')));
				buffer = buffer.subarray(4 + length);
			}
		});
		stream.on('end', () => resolve(seen));
		// The host serves until stdin closes, so there is no other end signal.
		setTimeout(() => resolve(seen), 1500).unref?.();
	});
}

export async function saveThroughHost(destination, conversation = conversationFromPage(), id = 'e2e-1') {
	if (!existsSync(hostBinary)) {
		throw new Error(`no host binary at ${hostBinary}; run bridge/host/build.sh first`);
	}
	const host = spawn(hostBinary);
	const responses = readResponses(host.stdout);

	host.stdin.write(frame({
		version: 1,
		id,
		action: 'saveConversation',
		conversation,
		destination,
		behaviour: 'auto',
	}));
	host.stdin.end();

	return responses;
}

// Run directly: save into a folder and print what came out.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
	const destination = destinationArg ?? mkdtempSync(join(tmpdir(), 'clip-e2e-'));
	const responses = await saveThroughHost(destination);

	const fail = (message, detail) => {
		console.error(message);
		if (detail) console.error(JSON.stringify(detail, null, 2));
		process.exit(1);
	};

	const failure = responses.find((r) => r.ok === false);
	if (failure) fail('the host refused the request', failure);

	const written = readdirSync(destination).filter((name) => name.endsWith('.md'));
	if (written.length === 0) fail('the host reported success but wrote nothing');
	const text = readFileSync(join(destination, written[0]), 'utf8');

	// Saving the same conversation again has to change nothing. If it does, the
	// file is rewritten on every press, and the archive slowly fills with copies
	// that differ only in a timestamp.
	const second = await saveThroughHost(destination, conversationFromPage(), 'e2e-2');
	const action = second.find((r) => r.ok)?.result?.action;
	if (action !== 'unchanged') fail(`a second save of the same conversation reported "${action}", not "unchanged"`);

	const after = readFileSync(join(destination, written[0]), 'utf8');
	if (after !== text) fail('a second save rewrote the file');

	if (process.argv.includes('--print')) console.log(text);
	console.log(`ok: wrote ${written[0]}, and a second save was a no-op`);
	process.exit(0);
}

/**
 * The native messaging round trip, against a model of the real transport.
 *
 * The previous implementation added a 4-byte length prefix before
 * `port.postMessage`, on the belief that `chrome.runtime` hands raw bytes to the
 * host. It does not: it serialises the value and adds that prefix itself, so the
 * host read our prefix as the first four bytes of a JSON document and every
 * request came back malformed.
 *
 * No test could have caught it, because every test spoke to a fake that was
 * written to match the code rather than the browser. So the fake here is written
 * to match the *browser*: it adds the prefix on the way in and strips it on the
 * way out, exactly as Chrome does. If the extension ever prefixes its own
 * messages again, the fake hands the host something the host cannot parse -- and
 * this fails.
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { saveConversation } from '../src/extract.js';

/**
 * A stand-in for `chrome.runtime` that frames the way Chrome frames.
 *
 * @param host the Swift app, expressed as something that reads framed messages
 */
function chromeTalkingTo(host, { wedged = false } = {}) {
	const sent = [];

	return {
		sent,
		runtime: {
			lastError: null,
			connectNative(name) {
				let onMessage = () => {};
				let onDisconnect = () => {};
				const port = {
					// Chrome serialises the value and prefixes the length. It does
					// not pass bytes through untouched.
					postMessage(value) {
						const body = Buffer.from(JSON.stringify(value), 'utf8');
						const frame = Buffer.alloc(4 + body.length);
						frame.writeUInt32LE(body.length, 0);
						body.copy(frame, 4);
						sent.push({ name, bytes: frame });

						// The host answers with its own framed message, and the
						// browser hands the content script the decoded value. A
						// host that is not there disconnects with nothing sent,
						// which is what `connectNative` does when no process
						// accepts the connection.
						// A wedged host neither answers nor hangs up, which is a
						// different failure from one that is not there: nothing can
						// be said about why, and only a timeout will end it.
						if (wedged) return;

						queueMicrotask(() => {
							const reply = host(Buffer.concat(sent.map((m) => m.bytes)));
							if (reply === undefined) {
								onDisconnect();
								return;
							}
							onMessage(JSON.parse(reply.payload.toString('utf8')));
							onDisconnect();
						});
					},
					disconnect() {},
					onMessage: { addListener: (fn) => (onMessage = fn) },
					onDisconnect: { addListener: (fn) => (onDisconnect = fn) },
				};
				return port;
			},
		},
	};
}

/** The host, as the Swift one behaves: read a length prefix, answer with one. */
function host(responder) {
	return (buffer) => {
		if (buffer.length < 4) return undefined;
		const length = buffer.readUInt32LE(0);
		assert.equal(
			buffer.length,
			4 + length,
			'the host could not find the end of the message: the framing is wrong'
		);
		const json = buffer.subarray(4, 4 + length).toString('utf8');
		// A host that cannot parse the JSON is what a double-prefixed message
		// looks like from the other side.
		const request = JSON.parse(json);

		const payload = Buffer.from(JSON.stringify(responder(request)), 'utf8');
		const frame = Buffer.alloc(4 + payload.length);
		frame.writeUInt32LE(payload.length, 0);
		payload.copy(frame, 4);
		return { payload: frame.subarray(4) };
	};
}

const conversation = {
	title: 'Thread',
	source: 'claude',
	model: null,
	url: 'https://claude.ai/chat/abc',
	turns: [{ role: 'user', body: 'question' }],
};

test('the host can read what the extension sends', async () => {
	// This is the assertion that was impossible before: the message the extension
	// puts on the wire, parsed by something that behaves like the host.
	const chrome = chromeTalkingTo(
		host(() => ({ version: 1, id: 'r', ok: true, result: { path: '/tmp/Thread.md', action: 'writeNew' } }))
	);

	const result = await saveConversation(chrome, { conversation, confidence: null, behaviour: 'auto', timeoutMs: 500 });
	assert.equal(result.action, 'writeNew');
});

test('the request carries what the app requires', async () => {
	let seen = null;
	const chrome = chromeTalkingTo(
		host((request) => {
			seen = request;
			return { version: 1, id: 'r', ok: true, result: { path: '/tmp/Thread.md', action: 'writeNew' } };
		})
	);

	await saveConversation(chrome, { conversation, confidence: null, behaviour: 'auto', timeoutMs: 500 });

	assert.equal(seen.action, 'saveConversation');
	assert.equal(seen.conversation.turns[0].body, 'question');
	// The app stamps its own receipt time, so the extension must not send one
	// that could disagree.
	assert.equal(seen.conversation.extractedAt, undefined);
});

test('a refusal from the host carries its own code and message', async () => {
	const chrome = chromeTalkingTo(
		host(() => ({
			version: 1,
			id: 'r',
			ok: false,
			error: { code: 'noDestination', message: 'No destination was given.', recoverable: false },
		}))
	);

	await assert.rejects(
		() => saveConversation(chrome, { conversation, confidence: null, behaviour: 'auto', timeoutMs: 500 }),
		(error) => {
			assert.match(error.message, /No destination/);
			assert.equal(error.code, 'noDestination');
			assert.equal(error.recoverable, false);
			return true;
		}
	);
});

test('a silent host is reported rather than left spinning', async () => {
	// Nothing ever answers and the port never closes -- an app stuck on a save
	// panel, or a host whose output is not being drained. Without the timeout the
	// badge would show an ellipsis for ever, which is the one failure a user
	// cannot tell from a working save.
	const chrome = chromeTalkingTo(() => undefined, { wedged: true });
	await assert.rejects(
		() => saveConversation(chrome, { conversation, confidence: null, behaviour: 'auto', timeoutMs: 500 }),
		/did not answer/
	);
});

test('an app that is not installed says so', async () => {
	const chrome = chromeTalkingTo(() => undefined);
	// Chrome's wording for a missing host, which is the most common cause.
	chrome.runtime.lastError = { message: 'Specified native messaging host not found.' };

	await assert.rejects(
		() => saveConversation(chrome, { conversation, confidence: null, behaviour: 'auto', timeoutMs: 500 }),
		(error) => {
			assert.match(error.message, /does not appear to be installed/);
			assert.equal(error.recoverable, false);
			return true;
		}
	);
});

test('an extension id the app does not list is named as its own problem', async () => {
	const chrome = chromeTalkingTo(() => undefined);
	// Two causes present as silence with completely different fixes, and Chrome's
	// own message is what distinguishes them.
	chrome.runtime.lastError = { message: 'Access to the specified native messaging host is forbidden.' };

	await assert.rejects(
		() => saveConversation(chrome, { conversation, confidence: null, behaviour: 'auto', timeoutMs: 500 }),
		(error) => {
			assert.match(error.message, /has not authorised this extension/);
			return true;
		}
	);
});

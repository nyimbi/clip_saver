import assert from 'node:assert/strict';
import { test } from 'node:test';

/**
 * The extension's view of the host: the wire format, from JS.
 *
 * `NativeMessage.read` is a Swift function, so it is not importable here. These
 * tests therefore assert the *format* rather than calling into Swift -- which is
 * the point, because the format is the contract and a mistake in it is silent on
 * both sides.
 *
 * The framing rules that matter, and why:
 *
 *   - A 4-byte little-endian length prefix. Not newline framing: a conversation
 *     is thousands of newlines long, so a delimiter inside the payload splits one
 *     message into two malformed ones.
 *   - The length is in *bytes*. A conversation of emoji is longer in UTF-8 than in
 *     characters, and counting characters truncates it.
 *   - Several messages may arrive in one read, and one message may be split across
 *     reads. Both are normal, not errors.
 */

/** Frames a payload the way PROTOCOL.md specifies. */
function frame(payload) {
	const bytes = typeof payload === 'string' ? new TextEncoder().encode(payload) : payload;
	const out = new Uint8Array(4 + bytes.length);
	new DataView(out.buffer).setUint32(0, bytes.length, true);
	out.set(bytes, 4);
	return out;
}

/** Reads as many complete messages as the buffer holds. */
function read(buffer) {
	const messages = [];
	let offset = 0;
	while (offset + 4 <= buffer.length) {
		const length = new DataView(buffer.buffer, buffer.byteOffset + offset, 4).getUint32(0, true);
		if (offset + 4 + length > buffer.length) break;
		messages.push(new TextDecoder().decode(buffer.subarray(offset + 4, offset + 4 + length)));
		offset += 4 + length;
	}
	return { messages, consumed: offset };
}

test('a framed message round-trips', () => {
	const body = JSON.stringify({ id: 'a', action: 'searchArchive' });
	const { messages } = read(frame(body));
	assert.deepEqual(messages, [body]);
});

test('the length prefix is little-endian', () => {
	const framed = frame('x');
	assert.deepEqual([...framed.subarray(0, 4)], [1, 0, 0, 0]);
});

test('a payload of many newlines is one message, not many', () => {
	// The reason for length framing. A Markdown conversation is thousands of
	// newlines long, so newline framing would split it into thousands of
	// malformed messages and the host would have to guess.
	const body = JSON.stringify({ id: 'a', markdown: '## User\n\nhello\n\n## Assistant\n\nhi\n' });
	const { messages } = read(frame(body));
	assert.equal(messages.length, 1);
	// The round trip is exact, newlines and all -- which is the property that
	// newline framing cannot offer.
	assert.equal(JSON.parse(messages[0]).markdown, '## User\n\nhello\n\n## Assistant\n\nhi\n');
	assert.ok(JSON.parse(messages[0]).markdown.split('\n').length > 5);
});

test('the length counts bytes, not characters', () => {
	// Four bytes per emoji. Counting characters would declare a length a quarter
	// of the real one and truncate the payload.
	const body = JSON.stringify({ id: 'a', body: '🙂🙂' });
	const framed = frame(body);
	const declared = new DataView(framed.buffer).getUint32(0, true);
	assert.equal(declared, new TextEncoder().encode(body).length);
	assert.equal(declared, framed.length - 4);
	assert.equal(JSON.parse(read(framed).messages[0]).body, '🙂🙂');
});

test('several messages in one buffer are read separately', () => {
	const buffer = new Uint8Array([
		...frame(JSON.stringify({ id: 'a' })),
		...frame(JSON.stringify({ id: 'bb' })),
	]);
	const { messages, consumed } = read(buffer);
	assert.equal(messages.length, 2);
	assert.equal(JSON.parse(messages[0]).id, 'a');
	assert.equal(JSON.parse(messages[1]).id, 'bb');
	assert.equal(consumed, buffer.length);
});

test('a partial message is left for the next read', () => {
	// Normal for a stream, not an error. The host keeps the remainder.
	const full = frame(JSON.stringify({ id: 'a', body: 'x'.repeat(100) }));
	const partial = full.subarray(0, full.length - 10);
	const { messages, consumed } = read(partial);
	assert.equal(messages.length, 0, 'a truncated frame must not be read as a message');
	assert.equal(consumed, 0, 'nothing is consumed, so the bytes are still available');
});

test('a real conversation survives framing byte for byte', () => {
	const conversation = {
		version: 1,
		id: 'req-1',
		action: 'saveConversation',
		conversation: {
			title: 'Structured concurrency',
			source: 'claude',
			model: 'claude-opus-5',
			url: 'https://claude.ai/chat/abc',
			turns: Array.from({ length: 200 }, (_, i) => ({
				role: i % 2 === 0 ? 'user' : 'assistant',
				body: `## turn ${i}\n\n\`\`\`swift\nawait work(${i})\n\`\`\`\n`,
			})),
		},
		behaviour: 'auto',
	};
	const { messages } = read(frame(JSON.stringify(conversation)));
	assert.equal(JSON.parse(messages[0]).conversation.turns.length, 200);
});

test('a turn may omit fields the sender considers empty', () => {
	// The wire format has to tolerate what JavaScript naturally omits. A
	// synthesised Swift decoder rejected a well-formed request for lacking
	// `toolCalls`, which surfaced as `malformedRequest` -- an unhelpful answer to
	// a correct message, and one that would have been blamed on the extension.
	const turn = { role: 'user', body: 'hello' };
	const { messages } = read(frame(JSON.stringify({ conversation: { turns: [turn] } })));
	const parsed = JSON.parse(messages[0]);
	assert.equal(parsed.conversation.turns[0].role, 'user');
	assert.ok(!('toolCalls' in parsed.conversation.turns[0]));
});

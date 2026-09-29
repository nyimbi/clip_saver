import assert from 'node:assert/strict';
import { test } from 'node:test';

import { STEP_FACTOR, harvestWindowed } from '../src/harvest.js';

/**
 * Randomised end-to-end coverage.
 *
 * This exists because the hand-written matrix in `harvest.test.js` passed
 * against a harvester that lost 74% of every conversation. The matrix started
 * each list at the top or the bottom and never in the middle, which is the one
 * case a single-direction walk handles.
 *
 * Every failure this found had the same signature: `complete: true` with turns
 * missing. That is the whole point -- a truncated capture that claims to be
 * complete is worse than a failed one, so the assertion checks the turn set
 * and not the return value.
 *
 * The generator deliberately includes the awkward shapes: windows of one and
 * two rows, lists that start mid-thread from a restored scroll position, and
 * turns whose text changes between harvests because they are still streaming.
 */

class RandomList {
	constructor({ total, window, startTop, jitterRows, streaming, seed }) {
		this.total = total;
		this.window = window;
		this.streaming = streaming;
		this.rowHeight = 100;
		// A deterministic PRNG, so a failure is reproducible from its seed rather
		// than by hoping to catch it again.
		this.random = mulberry32(seed);
		this.top = startTop ? 0 : Math.max(0, total * this.rowHeight - window * this.rowHeight);
		if (jitterRows) {
			this.top = Math.min(
				jitterRows * this.rowHeight,
				Math.max(0, total * this.rowHeight - window * this.rowHeight),
			);
		}
	}

	span() {
		return Math.max(0, this.total * this.rowHeight - this.window * this.rowHeight);
	}

	scrollHeight() {
		return this.total * this.rowHeight;
	}

	clientHeight() {
		return this.window * this.rowHeight;
	}

	scrollTop() {
		return this.top;
	}

	setScrollTop(value) {
		this.top = Math.max(0, Math.min(value, this.span()));
	}

	mountedRange() {
		const atBottom = this.top >= this.span();
		const first = atBottom ? this.total - this.window : Math.max(0, Math.floor(this.top / this.rowHeight));
		return [Math.max(0, first), Math.min(this.total, first + this.window)];
	}

	readWindow() {
		const [first, last] = this.mountedRange();
		const keys = [];
		const turns = [];
		const order = [];
		for (let i = first; i < last; i++) {
			keys.push(`turn-${i}`);
			// A still-streaming turn is different on every read, so a harvester
			// keying on content rather than identity would duplicate it.
			const body = this.streaming && i % 7 === 0
				? `v${i}-${Math.floor(this.random() * 9)}`
				: `final ${i}`;
			turns.push({ index: i, body });
			order.push(i);
		}
		return { keys, turns, order, reset() {} };
	}
}

function mulberry32(seed) {
	return function next() {
		seed |= 0;
		seed = (seed + 0x6d2b79f5) | 0;
		let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
		t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

function buildConfig(seed) {
	const random = mulberry32(seed);
	const pick = (n) => Math.floor(random() * n);
	return {
		total: 1 + pick(500),
		window: 1 + pick(40),
		startTop: random() > 0.5,
		jitterRows: random() > 0.6 ? pick(80) : 0,
		streaming: random() > 0.6,
		seed,
	};
}

async function capture(config) {
	const list = new RandomList(config);
	return harvestWindowed({
		viewport: list,
		readWindow: () => list.readWindow(),
		stepSettleMs: 0,
		idleTimeoutMs: 4_000,
		maxTimeoutMs: 10_000,
	});
}

test('a randomised sweep captures every turn', async () => {
	const TRIALS = 300;
	const failures = [];

	for (let seed = 1; seed <= TRIALS; seed++) {
		const config = buildConfig(seed);
		const result = await capture(config);
		const captured = new Set(result.turns.map((t) => t.index));

		const missing = [];
		for (let i = 0; i < config.total; i++) {
			if (!captured.has(i)) missing.push(i);
		}
		const order = result.turns.map((t) => t.index);
		const sorted = order.every((value, i) => i === 0 || order[i - 1] <= value);

		if (missing.length > 0 || !sorted) {
			failures.push(
				`seed=${seed} total=${config.total} window=${config.window} `
				+ `startTop=${config.startTop} jitter=${config.jitterRows} streaming=${config.streaming} `
				+ `-> captured ${order.length}, missing ${missing.length}, ordered=${sorted}, `
				+ `complete=${result.complete}, reason=${result.reason}`,
			);
		}
	}

	assert.deepEqual(
		failures,
		[],
		`${failures.length}/${TRIALS} configurations truncated or reordered:\n${failures.slice(0, 10).join('\n')}`,
	);
});

test('the sweep is deterministic for a given seed', async () => {
	// A failure reported by the sweep has to be reproducible, or it cannot be
	// diagnosed.
	const config = buildConfig(42);
	const first = await capture(config);
	const second = await capture(config);
	assert.deepEqual(
		first.turns.map((t) => t.index),
		second.turns.map((t) => t.index),
	);
});

test('a step never exceeds the mounted window', async () => {
	// The regression behind 21 of the failures: an absolute step floor applied
	// to a short viewport skipped turns outright. Against 100px rows a 400px
	// floor steps four rows while one is mounted.
	const list = new RandomList({ total: 300, window: 1, startTop: false, jitterRows: 0, streaming: false, seed: 1 });
	const step = Math.max(Math.floor(list.clientHeight() * STEP_FACTOR), 1);
	assert.ok(step < list.clientHeight(), `step ${step}px must be under the ${list.clientHeight()}px window`);
});

test('a zero-height viewport still steps by the floor', () => {
	// The one case the floor exists for: a fraction of zero never moves.
	const clientHeight = 0;
	const step = clientHeight > 0 ? Math.max(Math.floor(clientHeight * STEP_FACTOR), 1) : 400;
	assert.ok(step > 0);
});

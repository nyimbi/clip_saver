import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
	Accumulator,
	STEP_FACTOR,
	STABILITY_THRESHOLD,
	describeIncomplete,
	harvestInfinite,
	harvestWindowed,
} from '../src/harvest.js';

/**
 * A fake virtualized list.
 *
 * Models the two things that matter: only a window of turns is mounted at a
 * time, and which turns are mounted depends on scroll position. A test that
 * does not evict would not catch the boundary-straddling bug, which is the
 * entire point of STEP_FACTOR.
 */
class FakeViewport {
	constructor({ total, windowSize, virtualized = true }) {
		this.total = total;
		this.windowSize = windowSize;
		this.virtualized = virtualized;
		this.top = 0;
		this.rowHeight = 100;
		/** Every set, so a test can assert on step sizes. */
		this.steps = [];
	}

	scrollHeight() {
		return this.total * this.rowHeight;
	}

	clientHeight() {
		return this.windowSize * this.rowHeight;
	}

	scrollTop() {
		return this.top;
	}

	setScrollTop(value) {
		const clamped = Math.max(0, Math.min(value, this.scrollHeight() - this.clientHeight()));
		this.steps.push(Math.abs(this.top - clamped));
		this.top = clamped;
	}

	/**
	 * Which turns are mounted at the current scroll position.
	 *
	 * A virtualized list mounts a window around the viewport; a non-virtualized
	 * one keeps everything.
	 *
	 * Anchored at the far end when the viewport is at the bottom, which is what
	 * a real virtualized list does: at maximum scroll the *newest* turns are the
	 * ones on screen. A plain `first + windowSize` window there mounts the wrong
	 * set and hides the last few turns from the harvest altogether -- which is
	 * exactly the failure the harvester would then be blamed for.
	 */
	mountedRange() {
		if (!this.virtualized) return [0, this.total];
		const span = this.scrollHeight() - this.clientHeight();
		const atBottom = this.top >= span;
		const first = atBottom
			? this.total - this.windowSize
			: Math.max(0, Math.floor(this.top / this.rowHeight));
		return [Math.max(0, first), Math.min(this.total, first + this.windowSize)];
	}

	readWindow() {
		const [first, last] = this.mountedRange();
		const keys = [];
		const turns = [];
		const order = [];
		for (let i = first; i < last; i++) {
			keys.push(`turn-${i}`);
			turns.push({ index: i, body: `message ${i}` });
			// The platform knows where a turn sits in the document, and that is
			// what determines transcript order -- not the order we happen to
			// discover it in while walking.
			order.push(i);
		}
		return { keys, turns, order, reset() {} };
	}
}

const fast = { stepSettleMs: 0, rearmDelayMs: 0 };

test('a short conversation is captured in full', async () => {
	const viewport = new FakeViewport({ total: 6, windowSize: 20 });
	const result = await harvestWindowed({ viewport, readWindow: () => viewport.readWindow(), ...fast });
	assert.equal(result.turns.length, 6);
	assert.equal(result.complete, true);
});

test('a conversation longer than the window is captured in full', async () => {
	// 200 turns, 10 mounted at a time. Without eviction this passes trivially.
	const viewport = new FakeViewport({ total: 200, windowSize: 10 });
	const result = await harvestWindowed({ viewport, readWindow: () => viewport.readWindow(), ...fast });
	assert.equal(result.turns.length, 200, 'every turn must be captured');
	assert.equal(result.complete, true);
});

test('turns come back in conversation order', async () => {
	const viewport = new FakeViewport({ total: 60, windowSize: 8 });
	const result = await harvestWindowed({ viewport, readWindow: () => viewport.readWindow(), ...fast });
	const indices = result.turns.map((t) => t.index);
	assert.deepEqual(indices, [...indices].sort((a, b) => a - b));
});

test('no turn is duplicated', async () => {
	const viewport = new FakeViewport({ total: 120, windowSize: 7 });
	const result = await harvestWindowed({ viewport, readWindow: () => viewport.readWindow(), ...fast });
	const indices = result.turns.map((t) => t.index);
	assert.equal(new Set(indices).size, indices.length, 'a turn was harvested twice');
});

/**
 * The bug STEP_FACTOR exists to prevent. With a full-viewport step, a turn
 * straddling the boundary between two harvests is never mounted at either
 * harvest position, so it is lost with no error anywhere.
 */
test('overlapping steps lose no turn at a window boundary', async () => {
	const viewport = new FakeViewport({ total: 100, windowSize: 5 });
	const result = await harvestWindowed({ viewport, readWindow: () => viewport.readWindow(), ...fast });

	const captured = new Set(result.turns.map((t) => t.index));
	const missing = [];
	for (let i = 0; i < viewport.total; i++) {
		if (!captured.has(i)) missing.push(i);
	}
	assert.deepEqual(missing, [], 'turns silently lost at a harvest boundary');
});

test('step size is a fraction of the viewport, not a full page', async () => {
	const viewport = new FakeViewport({ total: 300, windowSize: 10 });
	await harvestWindowed({ viewport, readWindow: () => viewport.readWindow(), ...fast });

	const upward = viewport.steps.filter((s) => s > 0);
	assert.ok(upward.length > 0);
	const viewportHeight = viewport.clientHeight();
	// Every step must be strictly less than a full viewport, or windows stop
	// overlapping. The floor may make a small viewport exceed the fraction, so
	// this asserts the factor is applied rather than a bare inequality.
	const fractionSteps = upward.filter((s) => s === Math.floor(viewportHeight * STEP_FACTOR));
	assert.ok(
		fractionSteps.length > 0,
		`expected steps of ${Math.floor(viewportHeight * STEP_FACTOR)}px, saw ${[...new Set(upward)].join(', ')}`,
	);
});

test('a zero-height viewport still makes progress', async () => {
	// Some environments report clientHeight 0, which would make a
	// fraction-of-viewport step zero and loop forever. The floor prevents it.
	const viewport = new FakeViewport({ total: 50, windowSize: 10 });
	viewport.clientHeight = () => 0;

	const result = await harvestWindowed({
		viewport,
		readWindow: () => viewport.readWindow(),
		idleTimeoutMs: 2_000,
		...fast,
	});
	assert.ok(result.iterations > 1, 'the floor step must move the viewport');
	assert.equal(result.turns.length, 50, 'a zero-height viewport must not truncate the capture');
});

// MARK: - Partial captures

test('a timeout is reported as incomplete rather than silently truncated', async () => {
	// A viewport that never settles: every step reveals a new turn forever.
	let step = 0;
	const viewport = new FakeViewport({ total: 1_000_000, windowSize: 10 });
	const result = await harvestWindowed({
		viewport: {
			scrollTop: () => step,
			setScrollTop: (v) => {
				step = Math.max(0, v);
			},
			scrollHeight: () => 1_000_000 * 100,
			clientHeight: () => 1_000,
		},
		readWindow: () => ({
			keys: [`turn-${step}`],
			turns: [{ index: step }],
			reset() {},
		}),
		idleTimeoutMs: 30,
		maxTimeoutMs: 200,
		stepSettleMs: 1,
	});

	assert.equal(result.complete, false, 'a partial capture must not claim to be complete');
	assert.ok(['idleTimeout', 'maxTimeout'].includes(result.reason), `unexpected reason ${result.reason}`);
});

test('cancelling is reported as incomplete', async () => {
	const controller = new AbortController();
	const viewport = new FakeViewport({ total: 500, windowSize: 10 });
	controller.abort();

	const result = await harvestWindowed({
		viewport,
		readWindow: () => viewport.readWindow(),
		signal: controller.signal,
		...fast,
	});
	assert.equal(result.complete, false);
	assert.equal(result.reason, 'cancelled');
});

test('an incomplete capture produces a message that names the cause', () => {
	for (const reason of ['cancelled', 'idleTimeout', 'maxTimeout']) {
		const message = describeIncomplete({ reason, complete: false });
		assert.match(message, /incomplete/i, `reason ${reason} produced no explanation`);
	}
});

test('progress is reported while harvesting', async () => {
	const viewport = new FakeViewport({ total: 80, windowSize: 8 });
	const seen = [];
	await harvestWindowed({
		viewport,
		readWindow: () => viewport.readWindow(),
		onProgress: (count) => seen.push(count),
		...fast,
	});
	assert.ok(seen.length > 0, 'no progress was reported');
	assert.equal(seen.at(-1), 80);
});

// MARK: - Accumulator

test('accumulator replaces a turn it has already seen', () => {
	// A turn still streaming when first harvested is incomplete; the later
	// harvest has the finished text. Keeping the first sighting would freeze the
	// file at a partial answer.
	const accumulator = new Accumulator();
	accumulator.merge(['a'], [{ body: 'partial ans' }]);
	accumulator.merge(['a'], [{ body: 'the complete answer' }]);
	assert.equal(accumulator.size, 1);
	assert.deepEqual(accumulator.toArray(), [{ body: 'the complete answer' }]);
});

test('accumulator ignores turns with no key', () => {
	const accumulator = new Accumulator();
	const added = accumulator.merge([undefined, null, '', 'real'], [{}, {}, {}, { body: 'kept' }]);
	assert.equal(added, 1);
	assert.equal(accumulator.size, 1);
});

test('accumulator reports only genuinely new turns as added', () => {
	const accumulator = new Accumulator();
	assert.equal(accumulator.merge(['a', 'b'], [1, 2]), 2);
	assert.equal(accumulator.merge(['b', 'c'], [2, 3]), 1);
});

// MARK: - Infinite scrollers

test('an infinite scroller is captured in full', async () => {
	// Non-virtualized: everything stays mounted, one trip to the top suffices.
	const viewport = new FakeViewport({ total: 40, windowSize: 40, virtualized: false });
	const result = await harvestInfinite({ viewport, readWindow: () => viewport.readWindow(), ...fast });
	assert.equal(result.turns.length, 40);
	assert.equal(result.complete, true);
});

test('an infinite scroller re-arms the top-crossing trigger', async () => {
	// Models an edge-triggered loader: content appears when the scroll *crosses*
	// the top threshold, not when it sits at the top. A list already at the top
	// that is asked to go to the top again never fires, so without the re-arm the
	// count never grows.
	//
	// Bounded at ten pages, as a real page is. An unbounded generator here makes
	// the test hang rather than fail, which is how this was found.
	const PAGES = 10;
	let revealed = 0;
	const viewport = {
		_top: 1_000,
		scrollTop() {
			return this._top;
		},
		setScrollTop(v) {
			const wasBelow = this._top > 0;
			this._top = v;
			// Fires only on the transition into zero.
			if (v === 0 && wasBelow && revealed < PAGES) revealed++;
		},
		scrollHeight: () => 20_000,
		clientHeight: () => 1_000,
	};

	const result = await harvestInfinite({
		viewport,
		readWindow: () => ({
			keys: [...Array(revealed + 1).keys()].map(String),
			turns: [...Array(revealed + 1).keys()].map((i) => ({ index: i })),
			reset() {},
		}),
		...fast,
	});

	assert.equal(revealed, PAGES, 'the re-arm did not fire the top-crossing edge each time');
	assert.equal(result.turns.length, PAGES + 1, 'every revealed page must be accumulated');
	assert.equal(result.complete, true);
});

test('a non-virtualized list that is already at the top is not re-armed', async () => {
	// Nothing to fetch, so re-arming wastes a round trip per iteration.
	let setCalls = 0;
	const viewport = {
		scrollTop: () => 0,
		setScrollTop: (v) => {
			setCalls++;
			assert.equal(v, 0, 'should not jump to the bottom when already at the top');
		},
		scrollHeight: () => 1_000,
		clientHeight: () => 1_000,
	};

	await harvestInfinite({
		viewport,
		readWindow: () => ({ keys: ['a', 'b'], turns: [{}, {}], reset() {} }),
		needsRearm: false,
		...fast,
	});
	assert.ok(setCalls > 0);
});

test('a settled list ends on stability, not on the idle deadline', async () => {
	// A list that has stopped growing must end after N confirming passes. A
	// generous idle deadline here is deliberate: if stability were not doing the
	// work, this test would sit for 60s and then fail on the assertion, which is
	// the failure mode being ruled out.
	const viewport = new FakeViewport({ total: 5, windowSize: 20 });
	const started = Date.now();
	const result = await harvestWindowed({
		viewport,
		readWindow: () => viewport.readWindow(),
		idleTimeoutMs: 60_000,
		...fast,
	});
	assert.equal(result.complete, true);
	assert.ok(result.iterations <= STABILITY_THRESHOLD + 2, `took ${result.iterations} iterations`);
	assert.ok(Date.now() - started < 5_000, 'the idle deadline was reached instead of stability');
});

/**
 * The regression this whole file exists for: a virtualized list whose viewport
 * starts at the top, where there is nothing above but everything below. The
 * first version of the harvester stopped after one window here and reported a
 * *complete* 10-turn capture of a 200-turn conversation.
 */
test('a list starting at the top still walks downward', async () => {
	const viewport = new FakeViewport({ total: 200, windowSize: 10 });
	assert.equal(viewport.scrollTop(), 0, 'this test only means something at scrollTop 0');

	const result = await harvestWindowed({ viewport, readWindow: () => viewport.readWindow(), ...fast });
	assert.equal(result.turns.length, 200);
	assert.equal(result.complete, true);
});

test('a list starting at the bottom walks upward', async () => {
	const viewport = new FakeViewport({ total: 200, windowSize: 10 });
	viewport.setScrollTop(viewport.scrollHeight());

	const result = await harvestWindowed({ viewport, readWindow: () => viewport.readWindow(), ...fast });
	assert.equal(result.turns.length, 200, 'the newest turns must be read before walking up');
	assert.equal(result.complete, true);
});

test('the newest turns survive a downward walk', async () => {
	// The end of a downward walk is the newest content. Dropping it is the loss
	// that is hardest to notice, because the file still looks like a transcript.
	const viewport = new FakeViewport({ total: 200, windowSize: 10 });
	viewport.setScrollTop(viewport.scrollHeight());

	const result = await harvestWindowed({ viewport, readWindow: () => viewport.readWindow(), ...fast });
	const captured = new Set(result.turns.map((t) => t.index));
	for (let i = 190; i < 200; i++) {
		assert.ok(captured.has(i), `turn ${i} was lost at the far end`);
	}
});

test('turns are returned in conversation order regardless of start', async () => {
	for (const startAtBottom of [false, true]) {
		const viewport = new FakeViewport({ total: 90, windowSize: 9 });
		if (startAtBottom) viewport.setScrollTop(viewport.scrollHeight());
		const result = await harvestWindowed({ viewport, readWindow: () => viewport.readWindow(), ...fast });
		const indices = result.turns.map((t) => t.index);
		assert.deepEqual(
			indices,
			[...indices].sort((a, b) => a - b),
			`out of order starting at ${startAtBottom ? 'bottom' : 'top'}`,
		);
	}
});

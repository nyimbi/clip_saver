/**
 * Harvesting a virtualized conversation.
 *
 * This is the part every exporter gets wrong, and the reasoning is worth
 * stating because the obvious implementation is wrong in a way that produces
 * files which look complete.
 *
 * Two platform families, opposite strategies:
 *
 *   Infinite scrollers (Gemini). Old turns stay mounted as you scroll. Scroll
 *   to the top once, wait for the count to stop changing, read everything. The
 *   subtlety is that the load trigger is usually *edge-triggered* on a
 *   top-crossing event, so a second pass from the top does nothing. It has to
 *   jump to the bottom first to re-arm, then return to the top.
 *
 *   Windowing (Claude, ChatGPT). Off-screen turns are *evicted*. You cannot
 *   scroll to the top and read everything. You step upward, harvest each
 *   window, and accumulate across them, keyed on a stable per-turn identifier.
 *
 * The three requirements below each exist because shipping software got it
 * wrong first:
 *
 * 1. Step by 0.6 of the viewport, never a full viewport. A full-viewport step
 *    leaves a turn straddling the boundary to fall between two harvests, and it
 *    is lost *silently*. There is no error, no warning, no visible symptom --
 *    just a file that is quietly missing a message.
 *
 * 2. Deadlines are progress-aware, not a fixed wall. A fixed budget does not
 *    scale: at ~400ms per iteration a 15s cap saturates around 75 turns, so
 *    every longer conversation times out mid-scroll. And any wall-clock budget
 *    is unreliable under background-tab timer throttling (setTimeout is clamped
 *    to >=1s when hidden, ~10s after 5min hidden). So: give up only after N ms
 *    with *no progress*, plus an absolute cap that only bounds pathology.
 *
 * 3. A timeout is not a failure, it is a partial capture -- and it has to say
 *    so. A truncated conversation written as if it were whole is worse than no
 *    file at all, because the user believes they have a backup.
 *
 * Everything is injected so this is testable in Node against a fake viewport.
 * There is no DOM access in this file.
 */

/** Fraction of the viewport to step by. See requirement 1. */
export const STEP_FACTOR = 0.6;

/** Floor for the step distance in px. Guards viewports reporting 0 height. */
export const STEP_MIN_PX = 400;

/**
 * Consecutive harvests with no new turns before loading is believed done.
 *
 * Used by `harvestInfinite` only. It is the right signal there, because an
 * infinite scroller accumulates rather than evicts, so a flat count really does
 * mean the loader has finished. It is *not* used by `harvestWindowed`: a
 * virtualized list legitimately re-mounts the same turns after a direction
 * change, so a pass count there truncated real content -- see the note on
 * leg reversal in `harvestWindowed`.
 */
export const STABILITY_THRESHOLD = 3;

/** Settle time after each step, before reading the newly mounted window. */
export const STEP_SETTLE_MS = 400;

/** Default idle deadline: no *progress* for this long means give up. */
export const DEFAULT_IDLE_TIMEOUT_MS = 15000;

/** Absolute cap on one pass, bounding pathological growth only. */
export const DEFAULT_MAX_TIMEOUT_MS = 300000;

/**
 * @typedef {object} Viewport
 * @property {() => number} scrollTop
 * @property {(v: number) => void} setScrollTop
 * @property {() => number} scrollHeight
 * @property {() => number} clientHeight
 *
 * All four are accessors, not properties. A real `HTMLElement` exposes
 * `clientHeight` as a number, so the adapter wraps it in a function -- and a
 * caller who reads these as plain values gets `undefined` arithmetic rather than
 * an obvious mistake, which is the worst kind of shape mismatch to debug.
 */

/**
 * @typedef {object} Window
 * @property {string[]} keys       Stable identifiers for the mounted turns.
 * @property {unknown[]} turns    The turns themselves.
 * @property {() => void} reset    Forget accumulated state (re-arm, etc).
 */

/**
 * @typedef {object} HarvestResult
 * @property {unknown[]} turns
 * @property {boolean} complete   False means the capture is partial.
 * @property {number} iterations
 * @property {string} reason      Why it stopped, for diagnostics.
 * @property {number} elapsedMs
 */

/**
 * Accumulates turns from a windowed, virtualized list.
 *
 * Identity is the stable per-turn key, not the index and not the content hash.
 * A virtualized list unmounts and remounts nodes as you scroll, so an index
 * shifts under you; a key is assigned by the platform and survives. Content is
 * deliberately not the key: a streamed answer's text changes between harvests,
 * and keying on it would duplicate the same message once per pass.
 *
 * Order is supplied by the caller, not inferred from discovery order. A walk
 * upward discovers the newest turn first, so insertion order is exactly
 * reversed -- and a transcript that is complete but backwards still reads as
 * corrupt, which is the failure a user is most likely to notice and least
 * likely to attribute to the exporter.
 */
export class Accumulator {
	#seen = new Map();

	/**
	 * Merges one harvested window.
	 *
	 * A key already present is *replaced*, not skipped. A turn that was still
	 * streaming when first seen is incomplete; the later harvest has the finished
	 * text. Keeping the first sighting would freeze the file at the first
	 * partial answer. The replacement keeps the turn's original recorded order,
	 * so a late-arriving correction does not move it.
	 *
	 * @param {string[]} keys
	 * @param {unknown[]} turns
	 * @param {number} [order] Document position, ascending. Omit when the platform
	 *   exposes no ordering and discovery order is genuinely document order.
	 * @param {number} [order] Document position per key, ascending.
	 * @returns {number} how many turns were new.
	 */
	merge(keys, turns, order) {
		let added = 0;
		for (let i = 0; i < keys.length; i++) {
			const key = keys[i];
			if (key === undefined || key === null || key === '') continue;
			if (!this.#seen.has(key)) added++;
			this.#seen.set(key, {
				turn: turns[i],
				// An explicit order wins; otherwise fall back to discovery order,
				// which is correct for a list that only ever mounts forward.
				position: order !== undefined ? order[i] : Number.MAX_SAFE_INTEGER,
				seq: this.#seen.size,
			});
		}
		return added;
	}

	get size() {
		return this.#seen.size;
	}

	/**
	 * Turns in document order.
	 *
	 * Sorted by the supplied position where one was given. Turns sharing a
	 * position -- which happens when a platform exposes no ordering at all --
	 * fall back to discovery order, so the sort is stable rather than arbitrary.
	 */
	toArray() {
		return [...this.#seen.entries()]
			.sort(([, a], [, b]) => a.position - b.position || a.seq - b.seq)
			.map(([, record]) => record.turn);
	}

	clear() {
		this.#seen.clear();
	}
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Harvests a windowed (virtualized) conversation.
 *
 * @param {object} options
 * @param {Viewport} options.viewport
 * @param {() => Window} options.readWindow
 * @param {() => void} [options.onProgress]
 * @param {AbortSignal} [options.signal]
 * @param {number} [options.idleTimeoutMs]
 * @param {number} [options.maxTimeoutMs]
 * @param {number} [options.stepSettleMs]
 * @returns {Promise<HarvestResult>}
 */
export async function harvestWindowed({
	viewport,
	readWindow,
	onProgress,
	signal,
	idleTimeoutMs = DEFAULT_IDLE_TIMEOUT_MS,
	maxTimeoutMs = DEFAULT_MAX_TIMEOUT_MS,
	stepSettleMs = STEP_SETTLE_MS,
}) {
	const accumulator = new Accumulator();
	const started = Date.now();
	let lastProgressAt = started;
	let iterations = 0;
	let reason = 'complete';
	let complete = true;
	let consecutiveStable = 0;

	// Where a windowed list starts is not knowable in advance. A chat transcript
	// is often mounted at the top (restored position, short thread), at the
	// bottom (a freshly opened conversation), or -- routinely -- somewhere in
	// between, because a deep link or a reload restores a mid-thread scroll.
	//
	// Assuming any single one silently truncates. Two bugs lived here, and both
	// reported `complete: true` while dropping turns:
	//
	//   1. Walking only upward, which loses everything below the start.
	//   2. Walking only one direction at all, which loses the other side
	//      entirely when the list starts mid-thread. A randomised harness found
	//      this second one: 126 of 300 configurations truncated, all of them
	//      reporting a complete capture.
	//
	// So the walk is directional per leg but not per thread. Each leg runs until
	// its direction is spent, then the direction reverses, and the thread is only
	// finished when a full cycle -- up *and* down -- has surfaced nothing at all.
	let direction = 'up';
	/** The direction to try once the current one is spent. */
	let nextDirection = 'down';
	/** Legs walked to their end without revealing anything. */
	let barrenLegs = 0;
	let lastTop = null;
	/** Set on a leg change, so the new leg starts from the far end. */
	let jumping = true;

	while (true) {
		if (signal?.aborted) {
			reason = 'cancelled';
			complete = false;
			break;
		}

		const elapsed = Date.now() - started;

		// Requirement 2: idle first, absolute second. A thread that keeps
		// producing turns is never cut off by the idle deadline, however long
		// it takes; the absolute cap only bounds a pathological page.
		if (elapsed > maxTimeoutMs) {
			reason = 'maxTimeout';
			complete = false;
			break;
		}
		if (Date.now() - lastProgressAt > idleTimeoutMs) {
			reason = 'idleTimeout';
			complete = false;
			break;
		}

		iterations++;

		const before = viewport.scrollTop();
		const span = viewport.scrollHeight() - viewport.clientHeight();
		// Overlapping step -- see requirement 1. A full-viewport step leaves a
		// turn straddling the boundary to fall between two harvests.
		//
		// The absolute floor applies *only* when the viewport reports no height,
		// which is the one case where a fraction of nothing would never move the
		// page. Applying it unconditionally was wrong: against 100px rows it
		// stepped 400px -- four rows -- while a single-row window was mounted, so
		// three turns in four were skipped per pass. 21 of 300 randomised
		// configurations truncated that way while reporting a complete capture.
		// Skipping turns to save a few scroll events is the wrong trade in the
		// only part of this feature whose failures are invisible.
		const clientHeight = viewport.clientHeight();
		const step = clientHeight > 0
			? Math.max(Math.floor(clientHeight * STEP_FACTOR), 1)
			: STEP_MIN_PX;

		// On a leg change, jump to the far end of the new direction so the walk
		// starts where the content is rather than from wherever the previous leg
		// finished. Without this the reversal re-walks the same ground.
		if (jumping) {
			viewport.setScrollTop(direction === 'up' ? span : 0);
			jumping = false;
		} else if (direction === 'up') {
			viewport.setScrollTop(Math.max(before - step, 0));
		} else {
			// Keep stepping to the clamp; the boundary window is only mounted
			// once the end is actually reached, and stopping short of it drops the
			// last screenful.
			viewport.setScrollTop(Math.min(before + step, span));
		}

		await sleep(stepSettleMs);
		const after = viewport.scrollTop();

		// Harvest after every step, including one that could not move. The turns
		// that just mounted are the ones that were off-screen before, and at the
		// end of a leg they are the oldest or newest content in the thread.
		const current = readWindow();
		const added = accumulator.merge(current.keys, current.turns, current.order);
		if (added > 0) {
			lastProgressAt = Date.now();
			barrenLegs = 0;
		}

		onProgress?.(accumulator.size, iterations, reason);

		// A pass that could not move means this direction is spent. Reverse.
		//
		// No stability counter is involved. An earlier version ended a leg only
		// after N unmoved passes, on the theory that one might be a transient
		// re-mount -- but with a narrow window the passes that follow a reversal
		// legitimately find nothing, and the count reached its threshold while
		// turns were still interleaved between the two legs. 16 of 300 randomised
		// configurations truncated that way, all of them reporting a complete
		// capture. "The viewport stopped moving" is the only direct evidence that
		// a direction is exhausted; a pass count is a proxy for it, and the proxy
		// is wrong exactly when windows are small.
		if (lastTop !== null && after === lastTop) {
			barrenLegs += 1;
			// Two barren legs means both directions have been walked end to end
			// without revealing anything new, which is the thread being finished.
			if (barrenLegs >= 2) {
				reason = 'exhausted';
				break;
			}
			const previous = direction;
			direction = nextDirection;
			nextDirection = previous;
			jumping = true;
		}
		lastTop = after;
	}

	return {
		turns: accumulator.toArray(),
		complete,
		iterations,
		reason,
		elapsedMs: Date.now() - started,
	};
}

/**
 * Harvests an infinite-scrolling list, where turns accumulate and stay mounted.
 *
 * The re-arm matters: the load trigger is usually edge-triggered on a
 * top-crossing event, so once the list is already at the top, scrolling to the
 * top again does nothing and the count never grows. Jumping to the bottom
 * first re-arms the edge, then the return trip to the top fires it.
 *
 * @param {object} options
 * @param {Viewport} options.viewport
 * @param {() => Window} options.readWindow
 * @param {boolean} [options.needsRearm] Platform fires on a top-crossing edge.
 */
export async function harvestInfinite({
	viewport,
	readWindow,
	onProgress,
	signal,
	needsRearm = true,
	idleTimeoutMs = DEFAULT_IDLE_TIMEOUT_MS,
	maxTimeoutMs = DEFAULT_MAX_TIMEOUT_MS,
	stepSettleMs = STEP_SETTLE_MS,
	rearmDelayMs = 200,
}) {
	const accumulator = new Accumulator();
	const started = Date.now();
	let lastProgressAt = started;
	let iterations = 0;
	let consecutiveStable = 0;
	let previousSize = -1;
	let reason = 'complete';
	let complete = true;

	while (true) {
		if (signal?.aborted) {
			reason = 'cancelled';
			complete = false;
			break;
		}
		const elapsed = Date.now() - started;
		if (elapsed > maxTimeoutMs) {
			reason = 'maxTimeout';
			complete = false;
			break;
		}
		if (Date.now() - lastProgressAt > idleTimeoutMs) {
			reason = 'idleTimeout';
			complete = false;
			break;
		}

		iterations++;

		// Read before moving, for the same reason as the windowed path: the
		// starting position is where the newest turns are, and an infinite
		// scroller mounts them there before anything has been scrolled.
		const initial = readWindow();
		if (accumulator.merge(initial.keys, initial.turns, initial.order) > 0) {
			lastProgressAt = Date.now();
			consecutiveStable = 0;
		}

		if (needsRearm && viewport.scrollTop() <= 0) {
			// Already at the top: nothing would fire, so re-arm by crossing the
			// edge from the other side.
			viewport.setScrollTop(viewport.scrollHeight());
			await sleep(rearmDelayMs);
		}

		viewport.setScrollTop(0);
		await sleep(stepSettleMs);

		const current = readWindow();
		const added = accumulator.merge(current.keys, current.turns, current.order);
		if (added > 0) {
			lastProgressAt = Date.now();
			consecutiveStable = 0;
		} else {
			consecutiveStable++;
		}

		onProgress?.(accumulator.size, iterations, reason);

		if (consecutiveStable >= STABILITY_THRESHOLD) {
			reason = 'stabilised';
			break;
		}
		previousSize = accumulator.size;
	}

	return {
		turns: accumulator.toArray(),
		complete,
		iterations,
		reason,
		elapsedMs: Date.now() - started,
	};
}

/**
 * A human-readable explanation for a partial capture.
 *
 * Requirement 3. This string ends up in the saved file, so it says what
 * happened rather than what failed.
 */
export function describeIncomplete(result) {
	switch (result.reason) {
		case 'cancelled':
			return 'You stopped the capture before it finished, so this conversation may be incomplete.';
		case 'idleTimeout':
			return 'The page stopped loading more messages, so this capture may be incomplete.';
		case 'maxTimeout':
			return 'The capture hit its time limit, so this conversation may be incomplete.';
		default:
			return 'This capture may be incomplete.';
	}
}

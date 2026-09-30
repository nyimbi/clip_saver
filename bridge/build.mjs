/**
 * Builds the loadable extension.
 *
 * A Chrome extension is a sealed root. Every byte it runs has to live inside
 * `extension/`, and an MV3 content script is a *classic* script -- it has no
 * `import`, no module graph, and no way to reach `../src/`. The previous layout
 * had `content.js` and `background.js` sitting in that root importing modules
 * from outside it, which means the extension could not load at all. Nothing
 * caught it: the JavaScript tests imported `../src/*` directly and so never
 * touched the packaged files, and the Swift tests never saw JavaScript.
 *
 * So the sources stay where they are -- plain ESM, environment-free, unit-tested
 * in node -- and this script flattens them into one self-contained classic
 * script per entry point.
 *
 * Zero dependencies, deliberately. The runtime is a page scraper that reads
 * other people's DOM; a dependency tree is attack surface in someone else's
 * browser, and the graph here is six files with named exports and no cycles.
 * That last part is checked rather than assumed, because a cycle would silently
 * break live bindings under the snapshot semantics used below.
 *
 *   node build.mjs           build and validate
 *   node build.mjs --check   validate only, fail if the output is stale
 */

import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

/** Where the loadable extension is assembled. Inside the sealed root. */
const OUTPUT_DIR = join(here, 'extension', 'lib');

/**
 * The entry points, and what the manifest must call them.
 *
 * One list, because the manifest and the build reading two lists is how they
 * drift -- and a manifest pointing at a file that does not exist fails at load
 * time, in the browser, where the error says nothing useful.
 */
export const ENTRY_POINTS = [
	{ entry: join(here, 'extension', 'background.js'), out: 'lib/background.js' },
	{ entry: join(here, 'extension', 'content.js'), out: 'lib/content.js' },
];

// MARK: - Parsing

/** Matches a whole-line `import`/`export` statement at the start of a line. */
const IMPORT_NAMED = /^import\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]\s*;?\s*$/gm;
const IMPORT_DEFAULT = /^import\s+([A-Za-z_$][\w$]*)\s*from\s*['"]([^'"]+)['"]\s*;?\s*$/gm;
const IMPORT_BOTH = /^import\s+([A-Za-z_$][\w$]*)\s*,\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]\s*;?\s*$/gm;
const IMPORT_NAMESPACE = /^import\s+\*\s*as\s+([A-Za-z_$][\w$]*)\s*from\s*['"]([^'"]+)['"]\s*;?\s*$/gm;
const IMPORT_BARE = /^import\s*['"]([^'"]+)['"]\s*;?\s*$/gm;

/** `export const|let|var|function|async function|class` on its own line. */
const EXPORT_DECLARATION = /^export\s+(?=(?:const|let|var|function|async\s+function|class)\b)/gm;
/** `export { a, b as c }` on one line. */
const EXPORT_LIST = /^export\s*\{([^}]*)\}\s*;?\s*$/gm;
const EXPORT_DEFAULT = /^export\s+default\s+/gm;
const EXPORT_DEFAULT_ANY = /^export\s+default\s+/m;

/**
 * Splits a module into its imports, its exports, and the source with both
 * removed.
 *
 * Only rewrites statements that start a line and are complete on it, apart from
 * the `export ` prefix, which is stripped wherever it appears. That is enough for
 * this codebase and it is a feature rather than a limitation: a transform that
 * had to understand where a multi-line `export const X = [` ended would be a
 * transform that could get it wrong. An import this misses becomes a syntax
 * error at load, in a build that ran, which is a loud failure.
 */
function parseModule(source, file) {
	const imports = [];
	const exported = new Set();
	let body = source;

	const takeNames = (clause, from) => {
		for (const piece of clause.split(',')) {
			const trimmed = piece.trim();
			if (!trimmed) continue;
			// `a as b` -- the local name is what has to exist in this scope.
			const local = trimmed.split(/\s+as\s+/)[0].trim();
			imports.push({ kind: 'named', local, from });
		}
	};

	// Order matters only in that each pattern must run before the simpler ones
	// would match part of it, so the specific forms go first.
	for (const [pattern, handler] of [
		[IMPORT_BOTH, (m) => {
			imports.push({ kind: 'default', local: m[1], from: m[3] });
			takeNames(m[2], m[3]);
		}],
		[IMPORT_NAMESPACE, (m) => imports.push({ kind: 'namespace', local: m[1], from: m[2] })],
		[IMPORT_NAMED, (m) => takeNames(m[1], m[2])],
		[IMPORT_DEFAULT, (m) => imports.push({ kind: 'default', local: m[1], from: m[2] })],
		[IMPORT_BARE, (m) => imports.push({ kind: 'bare', local: null, from: m[1] })],
	]) {
		body = body.replace(pattern, (...args) => {
			handler(args);
			return '';
		});
	}

	for (const match of source.matchAll(EXPORT_LIST)) {
		for (const piece of match[1].split(',')) {
			const trimmed = piece.trim();
			if (!trimmed) continue;
			// `a as b` exports b, which is the local name.
			exported.add(trimmed.split(/\s+as\s+/)[0].trim());
		}
	}
	body = body.replace(EXPORT_LIST, '');

	// `export default` has no single-word form that can be renamed, so it is
	// kept under a reserved name. Tested with a non-global regex, because a
	// `/g` regex carries `lastIndex` between calls and would skip matches
	// depending on what ran before it.
	if (EXPORT_DEFAULT_ANY.test(body)) {
		exported.add('default');
		body = body.replace(EXPORT_DEFAULT, 'const __default = ');
	}

	// The declaration form: drop the keyword, and read the name out of what
	// follows it.
	//
	// `replace` hands the replacer the *match*, and the match here is only the
	// `export ` prefix -- the lookahead consumes nothing. So the declaration's
	// name is read from the text at the match's offset, not from the match
	// itself. Reading it from the match finds no name at all and silently exports
	// nothing, which is a bundle that builds cleanly and throws
	// "adapterFor is not a function" on the first call.
	body = body.replace(EXPORT_DECLARATION, (match, offset, full) => {
		const after = full.slice(offset + match.length);
		const named = /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)/.exec(after)
			?? /^(?:async\s+function|function|class)\s+([A-Za-z_$][\w$]*)/.exec(after);
		if (named) exported.add(named[1]);
		else throw new Error(`${file}: could not read the name of "${match}${after.split('\n')[0]}"`);
		return '';
	});

	if (/^\s*export\b/m.test(body)) {
		const line = /.*^\s*export\b.*$/m.exec(body)?.[0]?.trim();
		throw new Error(`${file}: unsupported export form -- ${line}`);
	}

	return { imports, exported: [...exported], body };
}

// MARK: - Graph

/** The module id used inside the bundle: a repo-relative POSIX path. */
const idOf = (file) => relative(here, file).split(sep).join('/');

function resolveSpecifier(fromFile, specifier) {
	if (!specifier.startsWith('.')) {
		throw new Error(
			`${idOf(fromFile)}: imports "${specifier}". The extension may not load code from ` +
				'outside the extension root, and the build has no network step, so a bare ' +
				'specifier is a dependency we would have to vendor by hand.'
		);
	}
	const target = resolve(dirname(fromFile), specifier);
	if (!existsSync(target)) {
		throw new Error(`${idOf(fromFile)}: imports "${specifier}", which does not exist`);
	}
	return target;
}

/**
 * Walks the graph from an entry point and returns modules in dependency order.
 *
 * A cycle throws rather than being handled. Under the snapshot bindings used by
 * the emitted code (`const { a } = __require(...)`), a cycle would give one
 * module an incomplete view of another -- the kind of bug that appears as a
 * `undefined` three layers away, only in production, only sometimes.
 */
function collectModules(entry) {
	const modules = new Map();
	const visiting = new Set();

	const visit = (file, from) => {
		const id = idOf(file);
		if (modules.has(id)) return id;
		if (visiting.has(id)) {
			throw new Error(
				`import cycle: ${idOf(from)} -> ${id}. The emitted bindings are snapshots, ` +
					'so a cycle would silently produce undefined values.'
			);
		}
		visiting.add(id);

		const parsed = parseModule(readFileSync(file, 'utf8'), id);
		for (const entryImport of parsed.imports) {
			visit(resolveSpecifier(file, entryImport.from), file);
		}

		visiting.delete(id);
		modules.set(id, { id, file, ...parsed });
		return id;
	};

	visit(entry, entry);
	return [...modules.values()];
}

// MARK: - Emit

function emit(modules, entryId) {
	const parts = [];
	parts.push('/* Generated by bridge/build.mjs -- do not edit. Source: bridge/src, bridge/extension. */');
	parts.push('(function () {');
	parts.push("'use strict';");
	parts.push('var __modules = {};');
	parts.push('var __cache = {};');
	parts.push(`function __require(id) {
		if (id in __cache) return __cache[id];
		var factory = __modules[id];
		if (!factory) throw new Error('module not bundled: ' + id);
		// Assigned only after the factory returns, so a module that throws leaves
		// nothing half-built in the cache for the next caller to find.
		return (__cache[id] = factory(__require));
	}`);

	for (const mod of modules) {
		const bindings = mod.imports
			.map((entryImport) => {
				if (entryImport.kind === 'bare') return '';
				const target = `__require(${JSON.stringify(idOf(resolveSpecifier(mod.file, entryImport.from)))})`;
				if (entryImport.kind === 'namespace') return `var ${entryImport.local} = ${target};`;
				if (entryImport.kind === 'default') return `var ${entryImport.local} = ${target}.default;`;
				return `var ${entryImport.local} = ${target}.${entryImport.local};`;
			})
			.join('\n');
		// Returns the export object, so a module's own scope is private and two
		// modules can both export a `RELIABLE` without colliding. There are two
		// right now.
		const returns = mod.exported.map((name) => `\t\t${name}: ${name},`).join('\n');
		parts.push(
			`__modules[${JSON.stringify(mod.id)}] = function (__require) {\n` +
				`${bindings}\n${mod.body}\n` +
				`return {\n${returns}\n};\n};`
		);
	}

	parts.push(`__require(${JSON.stringify(entryId)});`);
	parts.push('})();');
	return parts.join('\n\n');
}

// MARK: - Validate

/**
 * Checks the assembled extension against the mistakes that only show up at load
 * time in a browser, where the message is "Failed to load extension" and
 * nothing else.
 */
function validate(outputDir, manifest) {
	const problems = [];

	const scriptFiles = new Set([
		...ENTRY_POINTS.map((point) => point.out),
		...(manifest.content_scripts ?? []).flatMap((entry) => entry.js ?? []),
		...(manifest.background?.service_worker ? [manifest.background.service_worker] : []),
	]);

	for (const declared of scriptFiles) {
		const file = join(outputDir, declared);
		if (!existsSync(file)) {
			problems.push(`the manifest names ${declared}, which the build did not produce`);
			continue;
		}
		if (statSync(file).size === 0) problems.push(`${declared} is empty`);
	}

	// A leftover `import` is the specific failure this build exists to prevent,
	// and it is a one-line check rather than a load-and-hope.
	for (const { out } of ENTRY_POINTS) {
		const file = join(outputDir, out);
		if (!existsSync(file)) continue;
		const source = readFileSync(file, 'utf8');
		if (/^\s*import\s/m.test(source)) {
			problems.push(`${out} still contains an import statement; an MV3 content script is a classic script`);
		}
		if (/^\s*export\s/m.test(source)) {
			problems.push(`${out} still contains an export statement`);
		}
		if (/\bfrom\s+['"]\.\./.test(source)) {
			problems.push(`${out} references a path outside the extension root`);
		}
	}

	if (manifest.host_permissions?.includes('<all_urls>')) {
		problems.push(
			'`<all_urls>` is declared. The page menu item is reached through a context-menu click, ' +
				'which grants `activeTab` for that page, so no standing access to every site is needed.'
		);
	}

	return problems;
}

// MARK: - Build

export function build({ check = false } = {}) {
	const manifestPath = join(here, 'extension', 'manifest.json');
	const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));

	if (check) {
		const stale = ENTRY_POINTS.filter(({ out }) => {
			const built = join(here, 'extension', out);
			return !existsSync(built) || statSync(built).mtimeMs < statSync(join(here, 'extension', 'content.js')).mtimeMs;
		});
		if (stale.length > 0) {
			throw new Error(`the built extension is out of date: ${stale.map((p) => p.out).join(', ')}`);
		}
		return { written: [], validated: true };
	}

	if (!check) {
		rmSync(OUTPUT_DIR, { recursive: true, force: true });
		mkdirSync(OUTPUT_DIR, { recursive: true });
	}

	const written = [];
	for (const { entry, out } of ENTRY_POINTS) {
		const modules = collectModules(entry);
		const code = emit(modules, idOf(entry));
		const target = join(here, 'extension', out);
		mkdirSync(dirname(target), { recursive: true });
		writeFileSync(target, code);
		written.push(out);
	}

	const problems = validate(join(here, 'extension'), manifest);
	if (problems.length > 0) {
		for (const problem of problems) console.error(`  - ${problem}`);
		throw new Error(`the built extension would not load: ${problems.length} problem(s)`);
	}

	return { written, validated: true, sizes: written.map((out) => ({ out, modules: countModules(out) })) };
}

function countModules(out) {
	const source = readFileSync(join(here, 'extension', out), 'utf8');
	return (source.match(/^__modules\[/gm) ?? []).length;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	try {
		const check = process.argv.includes('--check');
		const result = build({ check });
		if (check) {
			console.log('the built extension is up to date');
		} else {
			for (const { out, modules } of result.sizes) {
				console.log(`built extension/${out} (${modules} modules)`);
			}
			console.log('the assembled extension validates against its manifest');
		}
	} catch (error) {
		console.error(error.message);
		process.exit(1);
	}
}

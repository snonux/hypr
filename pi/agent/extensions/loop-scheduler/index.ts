import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";

const DEFAULT_INTERVAL_MS = 10 * 60 * 1000;
const MAX_JOBS = 50;

// Path to the presets markdown file. ~/.pi -> hypr/pi/ (not pi/agent/), so the agent
// config lives one level deeper at ~/.pi/agent/.
const PRESETS_FILE = path.join(homedir(), ".pi", "agent", "extensions", "loop-scheduler", "loop-presets.md");

// Starter content written to the presets file if it doesn't exist yet.
const PRESETS_TEMPLATE = `# Loop presets
# Format: * name: INTERVAL prompt text
# INTERVAL supports: 5s, 10m, 2h, 1d, hourly, daily, every 30 minutes
#
# Examples — uncomment and adjust to taste:
# * health:  5m  check the build status
# * review:  1h  review the last 10 git commits
# * monitor: 10m check if there are any errors in the logs
`;

interface LoopJob {
	id: string;
	prompt: string;
	intervalMs: number;
	intervalLabel: string;
	createdAt: number;
	nextRunAt: number;
	pending: boolean;
	runs: number;
	lastRunAt?: number;
}

type TimerHandle = ReturnType<typeof setTimeout>;

function pluralize(value: number, singular: string): string {
	return `${value}${singular}`;
}

function formatInterval(ms: number): string {
	if (ms % (24 * 60 * 60 * 1000) === 0) return pluralize(ms / (24 * 60 * 60 * 1000), "d");
	if (ms % (60 * 60 * 1000) === 0) return pluralize(ms / (60 * 60 * 1000), "h");
	if (ms % (60 * 1000) === 0) return pluralize(ms / (60 * 1000), "m");
	if (ms % 1000 === 0) return pluralize(ms / 1000, "s");
	return `${ms}ms`;
}

function formatDelay(ms: number): string {
	if (ms <= 0) return "due now";
	if (ms < 60 * 1000) return `in ${Math.ceil(ms / 1000)}s`;
	if (ms < 60 * 60 * 1000) return `in ${Math.ceil(ms / (60 * 1000))}m`;
	if (ms < 24 * 60 * 60 * 1000) return `in ${Math.ceil(ms / (60 * 60 * 1000))}h`;
	return `in ${Math.ceil(ms / (24 * 60 * 60 * 1000))}d`;
}

function shortenPrompt(prompt: string, limit = 72): string {
	return prompt.length > limit ? `${prompt.slice(0, limit)}...` : prompt;
}

function parseDurationPhrase(raw: string): { intervalMs: number; label: string } | undefined {
	const text = raw.trim().toLowerCase();
	if (!text) return undefined;

	if (text === "hourly" || text === "every hour") return { intervalMs: 60 * 60 * 1000, label: "1h" };
	if (text === "daily" || text === "every day") return { intervalMs: 24 * 60 * 60 * 1000, label: "1d" };
	if (text === "minutely" || text === "every minute") return { intervalMs: 60 * 1000, label: "1m" };

	const match = text.match(
		/^(?:every\s+)?(\d+)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)$/i,
	);
	if (!match) return undefined;

	const amount = Number(match[1]);
	if (!Number.isFinite(amount) || amount <= 0) return undefined;

	const unit = match[2].toLowerCase();
	let intervalMs = 0;
	let label = "";

	if (["s", "sec", "secs", "second", "seconds"].includes(unit)) {
		intervalMs = amount * 1000;
		label = `${amount}s`;
	} else if (["m", "min", "mins", "minute", "minutes"].includes(unit)) {
		intervalMs = amount * 60 * 1000;
		label = `${amount}m`;
	} else if (["h", "hr", "hrs", "hour", "hours"].includes(unit)) {
		intervalMs = amount * 60 * 60 * 1000;
		label = `${amount}h`;
	} else if (["d", "day", "days"].includes(unit)) {
		intervalMs = amount * 24 * 60 * 60 * 1000;
		label = `${amount}d`;
	}

	if (intervalMs <= 0) return undefined;
	return { intervalMs, label };
}

function parseLoopRequest(rawArgs: string): { prompt: string; intervalMs: number; intervalLabel: string } | undefined {
	const text = rawArgs.trim();
	if (!text) return undefined;

	const trailingEvery = text.match(/^(.*\S)\s+every\s+(.+)$/i);
	if (trailingEvery) {
		const prompt = trailingEvery[1].trim();
		const duration = parseDurationPhrase(trailingEvery[2]);
		if (prompt && duration) {
			return { prompt, intervalMs: duration.intervalMs, intervalLabel: duration.label };
		}
	}

	const words = text.split(/\s+/);
	if (words.length > 1) {
		const firstDuration = parseDurationPhrase(words[0] ?? "");
		if (firstDuration) {
			return {
				prompt: words.slice(1).join(" "),
				intervalMs: firstDuration.intervalMs,
				intervalLabel: firstDuration.label,
			};
		}

		if ((words[0] ?? "").toLowerCase() === "every") {
			for (let i = 2; i <= Math.min(words.length - 1, 4); i++) {
				const candidate = words.slice(0, i).join(" ");
				const duration = parseDurationPhrase(candidate);
				if (duration) {
					return {
						prompt: words.slice(i).join(" "),
						intervalMs: duration.intervalMs,
						intervalLabel: duration.label,
					};
				}
			}
		}
	}

	return {
		prompt: text,
		intervalMs: DEFAULT_INTERVAL_MS,
		intervalLabel: formatInterval(DEFAULT_INTERVAL_MS),
	};
}

function formatJobLine(job: LoopJob): string {
	return `${job.id} every ${job.intervalLabel} ${job.pending ? "(pending)" : formatDelay(job.nextRunAt - Date.now())} ${shortenPrompt(job.prompt)}`;
}

interface LoopPreset {
	name: string; // lowercase canonical name
	intervalMs: number;
	intervalLabel: string;
	prompt: string;
}

// Parse a single "* name: INTERVAL prompt text" line. Returns undefined for non-matching lines
// (blank lines, comments, and malformed entries are silently skipped).
function parsePresetLine(line: string): LoopPreset | undefined {
	const trimmed = line.trim();
	if (!trimmed.startsWith("* ")) return undefined;
	const rest = trimmed.slice(2);
	const colonIdx = rest.indexOf(": ");
	if (colonIdx === -1) return undefined;
	const name = rest.slice(0, colonIdx).trim().toLowerCase();
	if (!name) return undefined;
	const afterColon = rest.slice(colonIdx + 2).trim();
	const spaceIdx = afterColon.search(/\s/);
	if (spaceIdx === -1) return undefined;
	const intervalToken = afterColon.slice(0, spaceIdx);
	const prompt = afterColon.slice(spaceIdx + 1).trim();
	if (!prompt) return undefined;
	const duration = parseDurationPhrase(intervalToken);
	if (!duration) return undefined;
	return { name, intervalMs: duration.intervalMs, intervalLabel: duration.label, prompt };
}

// Read and parse the presets file fresh on each call. Returns [] on any error (file not found, etc.).
function loadPresets(): LoopPreset[] {
	try {
		const content = readFileSync(PRESETS_FILE, "utf8");
		return content
			.split("\n")
			.map(parsePresetLine)
			.filter((p): p is LoopPreset => p !== undefined);
	} catch {
		return [];
	}
}

// Case-insensitive name lookup from the presets file.
function lookupPreset(name: string): LoopPreset | undefined {
	return loadPresets().find((p) => p.name === name.trim().toLowerCase());
}

// Human-readable preset list for /loop presets output.
function formatPresetList(): string {
	const presets = loadPresets();
	if (presets.length === 0) {
		return `No presets loaded. Use /loop edit to create ${PRESETS_FILE}`;
	}
	const lines = presets.map((p) => `  ${p.name} (${p.intervalLabel}): ${shortenPrompt(p.prompt, 60)}`);
	return [`Presets from ${PRESETS_FILE}:`, ...lines].join("\n");
}

export default function loopSchedulerExtension(pi: ExtensionAPI): void {
	const jobs = new Map<string, LoopJob>();
	const timers = new Map<string, TimerHandle>();
	let lastCtx: ExtensionContext | undefined;
	let agentBusy = false;
	let uiTick: TimerHandle | undefined;

	function rememberContext(ctx: ExtensionContext): void {
		lastCtx = ctx;
	}

	// Open the presets file in $VISUAL/$EDITOR, seeding it with the template if it doesn't exist.
	// Follows the same TUI stop/restart pattern as fresh-subagent's openInExternalEditor to avoid
	// terminal editor fighting the TUI for terminal control.
	async function openPresetsFile(ctx: ExtensionContext): Promise<void> {
		if (!existsSync(PRESETS_FILE)) {
			try {
				writeFileSync(PRESETS_FILE, PRESETS_TEMPLATE, "utf8");
			} catch (err) {
				notify(`Could not create presets file: ${err instanceof Error ? err.message : String(err)}`, "error", ctx);
				return;
			}
		}

		const editor = process.env.VISUAL ?? process.env.EDITOR;
		if (!editor) {
			notify(`No editor configured. Set $VISUAL or $EDITOR. File: ${PRESETS_FILE}`, "warning", ctx);
			return;
		}

		const command = `exec ${editor} ${JSON.stringify(PRESETS_FILE)}`;

		if (!ctx.hasUI) {
			spawnSync("bash", ["-lc", command], { stdio: "inherit", env: process.env });
			return;
		}

		await ctx.waitForIdle();
		await ctx.ui.custom<void>((tui, _theme, _kb, done) => {
			tui.stop();
			process.stdout.write("\x1b[2J\x1b[H");
			spawnSync("bash", ["-lc", command], { stdio: "inherit", env: process.env });
			tui.start();
			tui.requestRender(true);
			done(undefined);
			return { render: () => [], invalidate: () => {} };
		});
	}

	function clearJobTimer(id: string): void {
		const timer = timers.get(id);
		if (timer) {
			clearTimeout(timer);
			timers.delete(id);
		}
	}

	function clearAllTimers(): void {
		for (const timer of timers.values()) {
			clearTimeout(timer);
		}
		timers.clear();
	}

	function getOrderedJobs(): LoopJob[] {
		return [...jobs.values()].sort((a, b) => a.nextRunAt - b.nextRunAt || a.createdAt - b.createdAt);
	}

	function writeCommandOutput(text: string): void {
		process.stdout.write(`${text}\n`);
	}

	function updateUi(ctx: ExtensionContext | undefined = lastCtx): void {
		if (!ctx?.hasUI) return;

		const ordered = getOrderedJobs();
		if (ordered.length === 0) {
			ctx.ui.setStatus("loop-scheduler", undefined);
			ctx.ui.setWidget("loop-scheduler", undefined);
			stopUiTick();
			return;
		}

		ctx.ui.setStatus("loop-scheduler", ctx.ui.theme.fg("accent", `loop:${ordered.length}`));
		ctx.ui.setWidget(
			"loop-scheduler",
			[
				ctx.ui.theme.fg("accent", "Scheduled loops"),
				...ordered.slice(0, 3).map((job) => `${job.pending ? "⏸" : "⟳"} ${formatJobLine(job)}`),
				...(ordered.length > 3 ? [ctx.ui.theme.fg("muted", `+${ordered.length - 3} more`)] : []),
			],
			{ placement: "belowEditor" },
		);
		startUiTick();
	}

	// Tick every second so the countdown in the widget stays current.
	function startUiTick(): void {
		if (uiTick !== undefined) return;
		uiTick = setInterval(() => updateUi(), 1000);
	}

	function stopUiTick(): void {
		if (uiTick === undefined) return;
		clearInterval(uiTick);
		uiTick = undefined;
	}

	function notify(message: string, level: "info" | "warning" | "error" | "success" = "info", ctx?: ExtensionContext): void {
		const target = ctx ?? lastCtx;
		if (target?.hasUI) {
			target.ui.notify(message, level);
		} else {
			writeCommandOutput(message);
		}
	}

	function scheduleJobTimer(job: LoopJob): void {
		clearJobTimer(job.id);
		const delayMs = Math.max(100, job.nextRunAt - Date.now());
		const timer = setTimeout(() => {
			void handleJobDue(job.id);
		}, delayMs);
		timers.set(job.id, timer);
	}

	function dispatchLoopJob(job: LoopJob, reason: "timer" | "pending-drain"): void {
		if (agentBusy) {
			job.pending = true;
			updateUi();
			return;
		}

		agentBusy = true;
		job.pending = false;
		job.runs += 1;
		job.lastRunAt = Date.now();
		updateUi();

		try {
			pi.sendUserMessage(job.prompt);
			notify(`Loop ${job.id} fired (${reason}).`, "info");
		} catch (error) {
			agentBusy = false;
			job.pending = true;
			updateUi();
			const message = error instanceof Error ? error.message : String(error);
			notify(`Loop ${job.id} could not fire yet: ${message}`, "warning");
		}
	}

	function drainPendingJobs(): void {
		if (agentBusy) return;
		const nextPending = getOrderedJobs().find((job) => job.pending);
		if (!nextPending) return;
		dispatchLoopJob(nextPending, "pending-drain");
	}

	async function handleJobDue(id: string): Promise<void> {
		const job = jobs.get(id);
		if (!job) return;

		job.nextRunAt = Date.now() + job.intervalMs;
		scheduleJobTimer(job);

		if (agentBusy) {
			job.pending = true;
			updateUi();
			return;
		}

		dispatchLoopJob(job, "timer");
	}

	function createJob(prompt: string, intervalMs: number, intervalLabel: string): LoopJob {
		return {
			id: randomUUID().replace(/-/g, "").slice(0, 8),
			prompt,
			intervalMs,
			intervalLabel,
			createdAt: Date.now(),
			nextRunAt: Date.now() + intervalMs,
			pending: false,
			runs: 0,
		};
	}

	function resolveJob(idOrPrefix: string): LoopJob | undefined {
		const needle = idOrPrefix.trim().toLowerCase();
		if (!needle) return undefined;

		const exact = jobs.get(needle);
		if (exact) return exact;

		const matches = [...jobs.values()].filter((job) => job.id.startsWith(needle));
		return matches.length === 1 ? matches[0] : undefined;
	}

	function formatJobList(): string {
		const ordered = getOrderedJobs();
		if (ordered.length === 0) return "No active loop jobs.";

		return ordered.map((job) => `- ${formatJobLine(job)}`).join("\n");
	}

	function cancelJob(job: LoopJob): void {
		clearJobTimer(job.id);
		jobs.delete(job.id);
		updateUi();
	}

	pi.registerCommand("loop", {
		description:
			"Schedule a recurring prompt: /loop 10m <prompt>, /loop list, /loop cancel <id|all>, /loop <preset-name>",
		// Provide autocomplete for subcommands and preset names.
		//
		// CRITICAL: pi's autocomplete.js line 209 does:
		//   if (!argumentSuggestions || argumentSuggestions.length === 0) return null;
		// …and a null return from getSuggestions causes the TUI to fall back to filesystem
		// completion. Every branch here must return at least one item to prevent that.
		getArgumentCompletions: (prefix: string) => {
			// cancel/rm/delete <id|all>: expand to "cancel all" + active job IDs as soon as
			// the prefix matches the verb. Falls back to showing "cancel all" if no jobs exist.
			if (/^(cancel|rm|delete)(\s+\S*)?$/i.test(prefix)) {
				const verb = prefix.split(/\s+/)[0]!;
				const partial = (prefix.match(/^(?:cancel|rm|delete)\s+(\S*)$/i)?.[1] ?? "").toLowerCase();
				const results = [];
				if ("all".startsWith(partial)) {
					results.push({ value: `${verb} all`, label: `${verb} all`, description: "Cancel all active jobs" });
				}
				for (const job of jobs.values()) {
					if (job.id.startsWith(partial)) {
						results.push({
							value: `${verb} ${job.id}`,
							label: `${verb} ${job.id}`,
							description: shortenPrompt(job.prompt, 50),
						});
					}
				}
				// Always return at least one item — empty results would fall back to filesystem.
				return results.length > 0 ? results : [{ value: `${verb} all`, label: `${verb} all`, description: "Cancel all active jobs" }];
			}

			// preset <name>: expand to "preset <name>" items matching the partial name.
			// If the presets file is missing or empty, surface the edit suggestion so the
			// user gets a useful hint rather than filesystem completion.
			if (/^preset(\s+\S*)?$/i.test(prefix)) {
				const partial = (prefix.match(/^preset\s+(\S*)$/i)?.[1] ?? "").toLowerCase();
				const results = loadPresets()
					.filter((p) => p.name.startsWith(partial))
					.map((p) => ({
						value: `preset ${p.name}`,
						label: `preset ${p.name}`,
						description: `every ${p.intervalLabel} — ${shortenPrompt(p.prompt, 50)}`,
					}));
				// Always return at least one item to prevent filesystem fallback.
				return results.length > 0 ? results : [{ value: "edit", label: "edit", description: `No presets found — edit ${PRESETS_FILE}` }];
			}

			// Top-level: subcommand stubs and direct preset name shortcuts.
			const fixed = [
				{ value: "list", label: "list", description: "Show active loop jobs" },
				{ value: "cancel", label: "cancel", description: "Cancel a job: cancel <id|all>" },
				{ value: "preset", label: "preset", description: "Activate a named preset: preset <name>" },
				{ value: "edit", label: "edit", description: "Edit presets file in $EDITOR" },
				{ value: "presets", label: "presets", description: "List available presets" },
			];
			const presetItems = loadPresets().map((p) => ({
				value: p.name,
				label: p.name,
				description: `every ${p.intervalLabel} — ${shortenPrompt(p.prompt, 50)}`,
			}));
			const all = [...fixed, ...presetItems];
			if (!prefix) return all;
			const lower = prefix.toLowerCase();
			const filtered = all.filter((item) => item.value.startsWith(lower));
			// Return fixed list as fallback rather than null, so filesystem completion never fires.
			return filtered.length > 0 ? filtered : all;
		},
		handler: async (args, ctx) => {
			rememberContext(ctx);

			if (!ctx.hasUI) {
				writeCommandOutput("The /loop command requires an interactive or RPC session that stays open.");
				return;
			}

			const trimmed = args.trim();
			if (!trimmed || trimmed.toLowerCase() === "help") {
				notify(
					"Usage: /loop <interval> <prompt> | /loop <prompt> | /loop list | /loop cancel <id|all> | /loop edit | /loop presets | /loop preset <name> | /loop <preset-name>",
					"info",
					ctx,
				);
				return;
			}

			if (/^(list|ls)$/i.test(trimmed)) {
				notify(formatJobList(), "info", ctx);
				updateUi(ctx);
				return;
			}

			const cancelAll = /^(cancel|clear)\s+all$/i.test(trimmed);
			if (cancelAll) {
				const count = jobs.size;
				clearAllTimers();
				jobs.clear();
				updateUi(ctx);
				notify(count > 0 ? `Canceled ${count} loop job(s).` : "No active loop jobs.", "info", ctx);
				return;
			}

			const cancelMatch = trimmed.match(/^(?:cancel|rm|delete)\s+(\S+)$/i);
			if (cancelMatch) {
				const job = resolveJob(cancelMatch[1]);
				if (!job) {
					notify(`No loop job matched '${cancelMatch[1]}'.`, "warning", ctx);
					return;
				}
				cancelJob(job);
				notify(`Canceled loop ${job.id}.`, "info", ctx);
				return;
			}

			// Open the presets file in $VISUAL/$EDITOR for editing.
			if (/^edit$/i.test(trimmed)) {
				await openPresetsFile(ctx);
				return;
			}

			// List all available named presets from loop-presets.md.
			if (/^presets?$/i.test(trimmed)) {
				notify(formatPresetList(), "info", ctx);
				return;
			}

			// Explicit "preset <name>" subcommand — mirrors the single-word shorthand but more
			// discoverable and supports autocomplete at the third level.
			const presetCmd = trimmed.match(/^preset\s+(\S+)$/i);
			if (presetCmd) {
				const preset = lookupPreset(presetCmd[1]!);
				if (!preset) {
					notify(`No preset named '${presetCmd[1]}'. Use /loop presets to list available presets.`, "warning", ctx);
					return;
				}
				if (jobs.size >= MAX_JOBS) {
					notify(`Too many active loop jobs (${jobs.size}). Cancel one first.`, "warning", ctx);
					return;
				}
				const job = createJob(preset.prompt, preset.intervalMs, preset.intervalLabel);
				jobs.set(job.id, job);
				scheduleJobTimer(job);
				updateUi(ctx);
				notify(
					`Scheduled loop ${job.id} [${preset.name}] every ${job.intervalLabel}: ${shortenPrompt(job.prompt)}`,
					"success",
					ctx,
				);
				return;
			}

			// If the argument is a single word (no spaces), check if it matches a preset name.
			// Note: a preset named "hourly" or "daily" takes precedence over the interval shorthand.
			if (!/\s/.test(trimmed)) {
				const preset = lookupPreset(trimmed);
				if (preset) {
					if (jobs.size >= MAX_JOBS) {
						notify(`Too many active loop jobs (${jobs.size}). Cancel one first.`, "warning", ctx);
						return;
					}
					const job = createJob(preset.prompt, preset.intervalMs, preset.intervalLabel);
					jobs.set(job.id, job);
					scheduleJobTimer(job);
					updateUi(ctx);
					notify(
						`Scheduled loop ${job.id} [${preset.name}] every ${job.intervalLabel}: ${shortenPrompt(job.prompt)}`,
						"success",
						ctx,
					);
					return;
				}
			}

			if (jobs.size >= MAX_JOBS) {
				notify(`Too many active loop jobs (${jobs.size}). Cancel one before adding another.`, "warning", ctx);
				return;
			}

			const request = parseLoopRequest(trimmed);
			if (!request || !request.prompt.trim()) {
				notify("Could not parse /loop arguments. Example: /loop 10m check the build", "warning", ctx);
				return;
			}

			const job = createJob(request.prompt.trim(), request.intervalMs, request.intervalLabel);
			jobs.set(job.id, job);
			scheduleJobTimer(job);
			updateUi(ctx);
			notify(`Scheduled loop ${job.id} every ${job.intervalLabel}: ${shortenPrompt(job.prompt)}`, "success", ctx);
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		rememberContext(ctx);
		agentBusy = false;
		updateUi(ctx);
	});

	pi.on("agent_start", async (_event, ctx) => {
		rememberContext(ctx);
		agentBusy = true;
		updateUi(ctx);
	});

	pi.on("agent_end", async (_event, ctx) => {
		rememberContext(ctx);
		agentBusy = false;
		updateUi(ctx);
		drainPendingJobs();
	});

	pi.on("session_shutdown", async (_event, ctx) => {
		rememberContext(ctx);
		clearAllTimers();
		stopUiTick();
		jobs.clear();
		agentBusy = false;
		updateUi(ctx);
	});
}

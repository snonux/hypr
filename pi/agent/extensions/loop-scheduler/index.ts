import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";

const DEFAULT_INTERVAL_MS = 10 * 60 * 1000;
const MAX_JOBS = 50;
const MAX_WATCH_JOBS = 50;

// Path to the presets markdown file. ~/.pi -> hypr/pi/ (not pi/agent/), so the agent
// config lives one level deeper at ~/.pi/agent/.
const PRESETS_FILE = path.join(homedir(), ".pi", "agent", "extensions", "loop-scheduler", "loop-presets.md");
const WATCH_PRESETS_FILE = path.join(homedir(), ".pi", "agent", "extensions", "loop-scheduler", "watch-presets.md");

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

const WATCH_PRESETS_TEMPLATE = `# Watch presets
# Format:
# * name: idle => prompt text
# * name: contains needle => prompt text
#
# Examples — uncomment and adjust to taste:
# * idle-check: idle => summarize your current progress
# * error-alert: contains error => inspect the error and explain the cause
`;

interface LoopJob {
	id: string;
	prompt: string;
	intervalMs: number;
	intervalLabel: string;
	createdAt: number;
	nextRunAt: number;
	pending: boolean;
	paused: boolean; // true when the job is globally paused via /loop pause
	runs: number;
	lastRunAt?: number;
}

interface WatchIdleCondition {
	kind: "idle";
}

interface WatchContainsCondition {
	kind: "contains";
	needle: string;
}

type WatchCondition = WatchIdleCondition | WatchContainsCondition;

interface WatchJob {
	id: string;
	prompt: string;
	condition: WatchCondition;
	createdAt: number;
	pending: boolean;
	pendingReason?: "idle" | "contains";
	runs: number;
	lastRunAt?: number;
	lastMatchText?: string;
	lastIdleGeneration?: number;
}

interface WatchPreset {
	name: string;
	condition: WatchCondition;
	prompt: string;
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

function extractTextContent(content: unknown): string {
	if (typeof content === "string") return content.trim();
	if (!Array.isArray(content)) return "";

	return content
		.map((part) => {
			if (!part || typeof part !== "object") return "";
			const typedPart = part as { type?: string; text?: unknown };
			if (typedPart.type !== "text") return "";
			return typeof typedPart.text === "string" ? typedPart.text : "";
		})
		.join("\n")
		.trim();
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
	const state = job.paused ? "(paused)" : job.pending ? "(pending)" : formatDelay(job.nextRunAt - Date.now());
	return `${job.id} every ${job.intervalLabel} ${state} ${shortenPrompt(job.prompt)}`;
}

interface LoopPreset {
	name: string; // lowercase canonical name
	intervalMs: number;
	intervalLabel: string;
	prompt: string;
}

function parseWatchCondition(raw: string): WatchCondition | undefined {
	const trimmed = raw.trim();
	if (!trimmed) return undefined;
	if (/^idle$/i.test(trimmed)) return { kind: "idle" };

	const containsMatch = trimmed.match(/^contains\s+(.+)$/i);
	if (!containsMatch) return undefined;

	const needle = containsMatch[1]?.trim();
	if (!needle) return undefined;
	return { kind: "contains", needle };
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

// Parse a single "* name: CONDITION => prompt text" line for watch presets.
function parseWatchPresetLine(line: string): WatchPreset | undefined {
	const trimmed = line.trim();
	if (!trimmed.startsWith("* ")) return undefined;
	const rest = trimmed.slice(2);
	const colonIdx = rest.indexOf(": ");
	if (colonIdx === -1) return undefined;
	const name = rest.slice(0, colonIdx).trim().toLowerCase();
	if (!name) return undefined;
	const afterColon = rest.slice(colonIdx + 2).trim();
	const arrowIdx = afterColon.indexOf("=>");
	if (arrowIdx === -1) return undefined;
	const condition = parseWatchCondition(afterColon.slice(0, arrowIdx).trim());
	const prompt = afterColon.slice(arrowIdx + 2).trim();
	if (!condition || !prompt) return undefined;
	return { name, condition, prompt };
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

function loadWatchPresets(): WatchPreset[] {
	try {
		const content = readFileSync(WATCH_PRESETS_FILE, "utf8");
		return content
			.split("\n")
			.map(parseWatchPresetLine)
			.filter((preset): preset is WatchPreset => preset !== undefined);
	} catch {
		return [];
	}
}

// Case-insensitive name lookup from the presets file.
function lookupPreset(name: string): LoopPreset | undefined {
	return loadPresets().find((p) => p.name === name.trim().toLowerCase());
}

function lookupWatchPreset(name: string): WatchPreset | undefined {
	return loadWatchPresets().find((p) => p.name === name.trim().toLowerCase());
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

function formatWatchCondition(condition: WatchCondition): string {
	if (condition.kind === "idle") return "idle";
	return `contains ${JSON.stringify(condition.needle)}`;
}

function formatWatchList(watches: WatchJob[]): string {
	if (watches.length === 0) return "No active watch jobs.";

	return watches
		.map((job) => {
			const state = job.pending
				? `(pending${job.pendingReason === "contains" && job.lastMatchText ? `: ${shortenPrompt(job.lastMatchText, 20)}` : ""})`
				: formatWatchCondition(job.condition);
			return `- ${job.id} when ${state} ${shortenPrompt(job.prompt)}`.replace(/\s+/g, " ").trim();
		})
		.join("\n");
}

function formatWatchPresetList(): string {
	const presets = loadWatchPresets();
	if (presets.length === 0) {
		return `No watch presets loaded. Use /watch edit to create ${WATCH_PRESETS_FILE}`;
	}
	const lines = presets.map((preset) => `  ${preset.name} (${formatWatchCondition(preset.condition)}): ${shortenPrompt(preset.prompt, 60)}`);
	return [`Watch presets from ${WATCH_PRESETS_FILE}:`, ...lines].join("\n");
}

function parseWatchRequest(rawArgs: string): { condition: WatchCondition; prompt: string } | undefined {
	const text = rawArgs.trim();
	if (!text) return undefined;

	if (/^idle\b/i.test(text)) {
		const idleMatch = text.match(/^idle\s*=>\s*(.+)$/i);
		if (!idleMatch) return undefined;
		const prompt = idleMatch[1]?.trim();
		if (prompt) return { condition: { kind: "idle" }, prompt };
		return undefined;
	}

	if (/^contains\b/i.test(text)) {
		const containsMatch = text.match(/^contains\s+(.+?)\s*=>\s*(.+)$/i);
		if (!containsMatch) return undefined;
		const needle = containsMatch[1]?.trim();
		const prompt = containsMatch[2]?.trim();
		if (needle && prompt) return { condition: { kind: "contains", needle }, prompt };
		return undefined;
	}

	return { condition: { kind: "idle" }, prompt: text };
}

export default function loopSchedulerExtension(pi: ExtensionAPI): void {
	const jobs = new Map<string, LoopJob>();
	const watchJobs = new Map<string, WatchJob>();
	const timers = new Map<string, TimerHandle>();
	let lastCtx: ExtensionContext | undefined;
	let agentBusy = false;
	let currentAssistantText = "";
	let currentIdleGeneration = 0;
	let allPaused = false; // true when all loops are suspended via /loop pause
	let uiTick: TimerHandle | undefined;

	function rememberContext(ctx: ExtensionContext): void {
		lastCtx = ctx;
	}

	/** Scheduled messages are independent prompts that should queue when the agent is busy. */
	function sendScheduledUserMessage(prompt: string): void {
		pi.sendUserMessage(prompt, { deliverAs: "followUp" });
	}

	async function openPresetFile(ctx: ExtensionContext, filePath: string, template: string, errorPrefix: string): Promise<void> {
		if (!existsSync(filePath)) {
			try {
				writeFileSync(filePath, template, "utf8");
			} catch (err) {
				notify(`Could not create ${errorPrefix} presets file: ${err instanceof Error ? err.message : String(err)}`, "error", ctx);
				return;
			}
		}

		const editor = process.env.VISUAL ?? process.env.EDITOR;
		if (!editor) {
			notify(`No editor configured. Set $VISUAL or $EDITOR. File: ${filePath}`, "warning", ctx);
			return;
		}

		const command = `exec ${editor} ${JSON.stringify(filePath)}`;

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

	function getOrderedWatchJobs(): WatchJob[] {
		return [...watchJobs.values()].sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));
	}

	function writeCommandOutput(text: string): void {
		process.stdout.write(`${text}\n`);
	}

	function updateUi(ctx: ExtensionContext | undefined = lastCtx): void {
		if (!ctx?.hasUI) return;

		const orderedLoops = getOrderedJobs();
		const orderedWatches = getOrderedWatchJobs();
		if (orderedLoops.length === 0 && orderedWatches.length === 0) {
			ctx.ui.setStatus("loop-scheduler", undefined);
			ctx.ui.setWidget("loop-scheduler", undefined);
			stopUiTick();
			return;
		}

		// Status bar: append ⏸ when all loops are paused so the user can see it at a glance.
		const statusParts = [];
		if (orderedLoops.length > 0) {
			statusParts.push(allPaused ? `loop:${orderedLoops.length} ⏸` : `loop:${orderedLoops.length}`);
		}
		if (orderedWatches.length > 0) {
			statusParts.push(`watch:${orderedWatches.length}`);
		}
		const statusLabel = statusParts.join(" ");
		ctx.ui.setStatus("loop-scheduler", ctx.ui.theme.fg("accent", statusLabel));
		const widgetLines: string[] = [];
		if (orderedLoops.length > 0) {
			widgetLines.push(ctx.ui.theme.fg("accent", allPaused ? "Scheduled loops (paused)" : "Scheduled loops"));
			// ⏸ = globally paused, ⏳ = pending (agent busy), ⟳ = counting down
			widgetLines.push(
				...orderedLoops.slice(0, 3).map((job) => `${job.paused ? "⏸" : job.pending ? "⏳" : "⟳"} ${formatJobLine(job)}`),
			);
			if (orderedLoops.length > 3) {
				widgetLines.push(ctx.ui.theme.fg("muted", `+${orderedLoops.length - 3} more loop(s)`));
			}
		}
		if (orderedWatches.length > 0) {
			widgetLines.push(ctx.ui.theme.fg("accent", "Watch jobs"));
			widgetLines.push(
				...orderedWatches.slice(0, 3).map((job) => `${job.pending ? "⏳" : "◎"} ${formatWatchJobLine(job)}`),
			);
			if (orderedWatches.length > 3) {
				widgetLines.push(ctx.ui.theme.fg("muted", `+${orderedWatches.length - 3} more watch(s)`));
			}
		}
		ctx.ui.setWidget(
			"loop-scheduler",
			widgetLines,
			{ placement: "belowEditor" },
		);
		if (orderedLoops.length > 0) {
			startUiTick();
		} else {
			stopUiTick();
		}
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
			sendScheduledUserMessage(job.prompt);
			notify(`Loop ${job.id} fired (${reason}).`, "info");
		} catch (error) {
			agentBusy = false;
			job.pending = true;
			updateUi();
			const message = error instanceof Error ? error.message : String(error);
			notify(`Loop ${job.id} could not fire yet: ${message}`, "warning");
		}
	}

	function formatWatchJobLine(job: WatchJob): string {
		const condition = formatWatchCondition(job.condition);
		const state = job.pending
			? `(pending${job.pendingReason ? ` ${job.pendingReason}` : ""}${job.lastMatchText ? `: ${shortenPrompt(job.lastMatchText, 24)}` : ""})`
			: condition;
		return `${job.id} when ${state} ${shortenPrompt(job.prompt)}`.replace(/\s+/g, " ").trim();
	}

	function queueWatchJob(job: WatchJob, reason: "idle" | "contains", detail?: string): void {
		if (job.pending) return;
		job.pending = true;
		job.pendingReason = reason;
		if (detail) job.lastMatchText = detail;
		updateUi();
	}

	function queueIdleWatchJobs(): void {
		for (const job of watchJobs.values()) {
			if (job.condition.kind !== "idle") continue;
			if (job.lastIdleGeneration === currentIdleGeneration) continue;
			job.lastIdleGeneration = currentIdleGeneration;
			queueWatchJob(job, "idle");
		}
	}

	function queueMatchingWatchJobs(text: string): void {
		const trimmed = text.trim();
		if (!trimmed) return;
		for (const job of watchJobs.values()) {
			if (job.condition.kind !== "contains") continue;
			if (!trimmed.includes(job.condition.needle)) continue;
			job.lastMatchText = job.condition.needle;
			queueWatchJob(job, "contains", job.condition.needle);
		}
	}

	function dispatchWatchJob(job: WatchJob, reason: "idle" | "contains"): void {
		if (agentBusy) {
			job.pending = true;
			job.pendingReason = reason;
			updateUi();
			return;
		}

		agentBusy = true;
		job.pending = false;
		job.pendingReason = undefined;
		job.runs += 1;
		job.lastRunAt = Date.now();
		updateUi();

		try {
			sendScheduledUserMessage(job.prompt);
			notify(`Watch ${job.id} fired (${reason}).`, "info");
		} catch (error) {
			agentBusy = false;
			job.pending = true;
			job.pendingReason = reason;
			updateUi();
			const message = error instanceof Error ? error.message : String(error);
			notify(`Watch ${job.id} could not fire yet: ${message}`, "warning");
		}
	}

	function drainPendingWatchJobs(): void {
		if (agentBusy && !lastCtx?.isIdle()) return;
		agentBusy = false;
		const nextPending = getOrderedWatchJobs().find((job) => job.pending);
		if (!nextPending) return;
		dispatchWatchJob(nextPending, nextPending.pendingReason ?? nextPending.condition.kind);
	}

	function drainPendingJobs(): void {
		if (agentBusy && !lastCtx?.isIdle()) return;
		agentBusy = false;
		if (!allPaused) {
			const nextPendingLoop = getOrderedJobs().find((job) => job.pending);
			if (nextPendingLoop) {
				dispatchLoopJob(nextPendingLoop, "pending-drain");
				return;
			}
		}
		drainPendingWatchJobs();
	}

	async function handleJobDue(id: string): Promise<void> {
		const job = jobs.get(id);
		if (!job) return;
		// Guard: if loops were paused after the timer was set, skip firing.
		if (allPaused) return;

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
			// First fire is ASAP; handleJobDue then sets nextRunAt to now + intervalMs for the repeating cadence.
			nextRunAt: Date.now(),
			pending: false,
			paused: allPaused, // inherit the current global pause state so new jobs added while paused start paused
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

	function resolveWatchJob(idOrPrefix: string): WatchJob | undefined {
		const needle = idOrPrefix.trim().toLowerCase();
		if (!needle) return undefined;

		const exact = watchJobs.get(needle);
		if (exact) return exact;

		const matches = [...watchJobs.values()].filter((job) => job.id.startsWith(needle));
		return matches.length === 1 ? matches[0] : undefined;
	}

	function formatJobList(): string {
		const ordered = getOrderedJobs();
		if (ordered.length === 0) return "No active loop jobs.";

		return ordered.map((job) => `- ${formatJobLine(job)}`).join("\n");
	}

	function formatWatchJobList(): string {
		const ordered = getOrderedWatchJobs();
		return formatWatchList(ordered);
	}

	function cancelJob(job: LoopJob): void {
		clearJobTimer(job.id);
		jobs.delete(job.id);
		updateUi();
	}

	function cancelWatchJob(job: WatchJob): void {
		watchJobs.delete(job.id);
		updateUi();
	}

	// Suspend all loops: clear every timer and mark each job as paused.
	// The jobs remain in the map so they can be resumed later.
	function pauseAllJobs(): void {
		clearAllTimers();
		allPaused = true;
		for (const job of jobs.values()) {
			job.paused = true;
			job.pending = false; // pending state is stale once timers are cleared
		}
		updateUi();
	}

	// Resume all paused loops: reset each job's next-run time to a fresh interval
	// from now, reschedule its timer, and clear the paused flag.
	function resumeAllJobs(): void {
		allPaused = false;
		for (const job of jobs.values()) {
			job.paused = false;
			job.nextRunAt = Date.now() + job.intervalMs;
			scheduleJobTimer(job);
		}
		updateUi();
	}

	function createWatchJob(prompt: string, condition: WatchCondition): WatchJob {
		return {
			id: randomUUID().replace(/-/g, "").slice(0, 8),
			prompt,
			condition,
			createdAt: Date.now(),
			pending: false,
			runs: 0,
		};
	}

	pi.registerCommand("loop", {
		description:
			"Schedule a recurring prompt: /loop 10m <prompt>, /loop list, /loop cancel <id|all>, /loop pause, /loop cont, /loop <preset-name>",
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
				{ value: "pause", label: "pause", description: "Pause all active loops" },
				{ value: "cont", label: "cont", description: "Continue (resume) all paused loops" },
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
					"Usage: /loop <interval> <prompt> | /loop <prompt> | /loop list | /loop cancel <id|all> | /loop pause | /loop cont | /loop edit | /loop presets | /loop preset <name> | /loop <preset-name>",
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

			// Suspend all active loops without cancelling them.
			if (/^pause$/i.test(trimmed)) {
				if (jobs.size === 0) {
					notify("No active loop jobs to pause.", "info", ctx);
					return;
				}
				if (allPaused) {
					notify("Loops are already paused. Use /loop cont to resume.", "info", ctx);
					return;
				}
				pauseAllJobs();
				notify(`Paused ${jobs.size} loop job(s). Use /loop cont to resume.`, "info", ctx);
				return;
			}

			// Resume all loops that were suspended with /loop pause.
			if (/^cont(inue)?$/i.test(trimmed)) {
				if (jobs.size === 0) {
					notify("No active loop jobs.", "info", ctx);
					return;
				}
				if (!allPaused) {
					notify("Loops are not paused.", "info", ctx);
					return;
				}
				resumeAllJobs();
				notify(`Resumed ${jobs.size} loop job(s).`, "success", ctx);
				return;
			}

			// Open the presets file in $VISUAL/$EDITOR for editing.
			if (/^edit$/i.test(trimmed)) {
				await openPresetFile(ctx, PRESETS_FILE, PRESETS_TEMPLATE, "loop");
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

	pi.registerCommand("watch", {
		description:
			"Watch for agent idle or matching responses: /watch <prompt>, /watch idle => <prompt>, /watch contains <needle> => <prompt>, /watch list, /watch cancel <id|all>, /watch preset <name>",
		getArgumentCompletions: (prefix: string) => {
			if (/^(cancel|rm|delete)(\s+\S*)?$/i.test(prefix)) {
				const verb = prefix.split(/\s+/)[0]!;
				const partial = (prefix.match(/^(?:cancel|rm|delete)\s+(\S*)$/i)?.[1] ?? "").toLowerCase();
				const results = [];
				if ("all".startsWith(partial)) {
					results.push({ value: `${verb} all`, label: `${verb} all`, description: "Cancel all active watch jobs" });
				}
				for (const job of watchJobs.values()) {
					if (job.id.startsWith(partial)) {
						results.push({
							value: `${verb} ${job.id}`,
							label: `${verb} ${job.id}`,
							description: shortenPrompt(job.prompt, 50),
						});
					}
				}
				return results.length > 0 ? results : [{ value: `${verb} all`, label: `${verb} all`, description: "Cancel all active watch jobs" }];
			}

			if (/^preset(\s+\S*)?$/i.test(prefix)) {
				const partial = (prefix.match(/^preset\s+(\S*)$/i)?.[1] ?? "").toLowerCase();
				const results = loadWatchPresets()
					.filter((preset) => preset.name.startsWith(partial))
					.map((preset) => ({
						value: `preset ${preset.name}`,
						label: `preset ${preset.name}`,
						description: `${formatWatchCondition(preset.condition)} — ${shortenPrompt(preset.prompt, 50)}`,
					}));
				return results.length > 0 ? results : [{ value: "edit", label: "edit", description: `No watch presets found — edit ${WATCH_PRESETS_FILE}` }];
			}

			const fixed = [
				{ value: "list", label: "list", description: "Show active watch jobs" },
				{ value: "cancel", label: "cancel", description: "Cancel a watch: cancel <id|all>" },
				{ value: "idle", label: "idle", description: "Create an idle watch: idle => <prompt>" },
				{ value: "contains", label: "contains", description: "Create a substring watch: contains <needle> => <prompt>" },
				{ value: "preset", label: "preset", description: "Activate a named watch preset: preset <name>" },
				{ value: "edit", label: "edit", description: "Edit watch presets file in $EDITOR" },
				{ value: "presets", label: "presets", description: "List available watch presets" },
			];
			const presetItems = loadWatchPresets().map((preset) => ({
				value: preset.name,
				label: preset.name,
				description: `${formatWatchCondition(preset.condition)} — ${shortenPrompt(preset.prompt, 50)}`,
			}));
			const all = [...fixed, ...presetItems];
			if (!prefix) return all;
			const lower = prefix.toLowerCase();
			const filtered = all.filter((item) => item.value.startsWith(lower));
			return filtered.length > 0 ? filtered : all;
		},
		handler: async (args, ctx) => {
			rememberContext(ctx);

			if (!ctx.hasUI) {
				writeCommandOutput("The /watch command requires an interactive or RPC session that stays open.");
				return;
			}

			const trimmed = args.trim();
			if (!trimmed || trimmed.toLowerCase() === "help") {
				notify(
					"Usage: /watch <prompt> | /watch idle => <prompt> | /watch contains <needle> => <prompt> | /watch list | /watch cancel <id|all> | /watch edit | /watch presets | /watch preset <name> | /watch <preset-name>",
					"info",
					ctx,
				);
				return;
			}

			if (/^(list|ls)$/i.test(trimmed)) {
				notify(formatWatchJobList(), "info", ctx);
				updateUi(ctx);
				return;
			}

			const cancelAll = /^(cancel|clear)\s+all$/i.test(trimmed);
			if (cancelAll) {
				const count = watchJobs.size;
				watchJobs.clear();
				updateUi(ctx);
				notify(count > 0 ? `Canceled ${count} watch job(s).` : "No active watch jobs.", "info", ctx);
				return;
			}

			const cancelMatch = trimmed.match(/^(?:cancel|rm|delete)\s+(\S+)$/i);
			if (cancelMatch) {
				const job = resolveWatchJob(cancelMatch[1]);
				if (!job) {
					notify(`No watch job matched '${cancelMatch[1]}'.`, "warning", ctx);
					return;
				}
				cancelWatchJob(job);
				notify(`Canceled watch ${job.id}.`, "info", ctx);
				return;
			}

			if (/^edit$/i.test(trimmed)) {
				await openPresetFile(ctx, WATCH_PRESETS_FILE, WATCH_PRESETS_TEMPLATE, "watch");
				return;
			}

			if (/^presets?$/i.test(trimmed)) {
				notify(formatWatchPresetList(), "info", ctx);
				return;
			}

			const presetCmd = trimmed.match(/^preset\s+(\S+)$/i);
			if (presetCmd) {
				const preset = lookupWatchPreset(presetCmd[1]!);
				if (!preset) {
					notify(`No watch preset named '${presetCmd[1]}'. Use /watch presets to list available presets.`, "warning", ctx);
					return;
				}
				if (watchJobs.size >= MAX_WATCH_JOBS) {
					notify(`Too many active watch jobs (${watchJobs.size}). Cancel one first.`, "warning", ctx);
					return;
				}
				const job = createWatchJob(preset.prompt, preset.condition);
				watchJobs.set(job.id, job);
				updateUi(ctx);
				if (job.condition.kind === "idle" && !agentBusy) {
					currentIdleGeneration += 1;
					job.lastIdleGeneration = currentIdleGeneration;
					queueWatchJob(job, "idle");
					drainPendingJobs();
				}
				notify(
					`Scheduled watch ${job.id} [${preset.name}] when ${formatWatchCondition(job.condition)}: ${shortenPrompt(job.prompt)}`,
					"success",
					ctx,
				);
				return;
			}

			if (!/\s/.test(trimmed)) {
				const preset = lookupWatchPreset(trimmed);
				if (preset) {
					if (watchJobs.size >= MAX_WATCH_JOBS) {
						notify(`Too many active watch jobs (${watchJobs.size}). Cancel one first.`, "warning", ctx);
						return;
					}
					const job = createWatchJob(preset.prompt, preset.condition);
					watchJobs.set(job.id, job);
					updateUi(ctx);
					if (job.condition.kind === "idle" && !agentBusy) {
						currentIdleGeneration += 1;
						job.lastIdleGeneration = currentIdleGeneration;
						queueWatchJob(job, "idle");
						drainPendingJobs();
					}
					notify(
						`Scheduled watch ${job.id} [${preset.name}] when ${formatWatchCondition(job.condition)}: ${shortenPrompt(job.prompt)}`,
						"success",
						ctx,
					);
					return;
				}
			}

			if (watchJobs.size >= MAX_WATCH_JOBS) {
				notify(`Too many active watch jobs (${watchJobs.size}). Cancel one before adding another.`, "warning", ctx);
				return;
			}

			const request = parseWatchRequest(trimmed);
			if (!request || !request.prompt.trim()) {
				notify("Could not parse /watch arguments. Example: /watch idle => check whether you are idle", "warning", ctx);
				return;
			}

			const job = createWatchJob(request.prompt.trim(), request.condition);
			watchJobs.set(job.id, job);
			updateUi(ctx);
			if (job.condition.kind === "idle" && !agentBusy) {
				currentIdleGeneration += 1;
				job.lastIdleGeneration = currentIdleGeneration;
				queueWatchJob(job, "idle");
				drainPendingJobs();
			}
			notify(`Scheduled watch ${job.id} when ${formatWatchCondition(job.condition)}: ${shortenPrompt(job.prompt)}`, "success", ctx);
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		rememberContext(ctx);
		agentBusy = false;
		updateUi(ctx);
		queueIdleWatchJobs();
		drainPendingJobs();
	});

	pi.on("agent_start", async (_event, ctx) => {
		rememberContext(ctx);
		agentBusy = true;
		currentAssistantText = "";
		updateUi(ctx);
	});

	pi.on("message_update", async (event) => {
		if (!event || event.message?.role !== "assistant" || !event.assistantMessageEvent) return;
		const assistantEvent = event.assistantMessageEvent as { type?: string; delta?: unknown };
		if (assistantEvent.type !== "text_delta" || typeof assistantEvent.delta !== "string") return;
		currentAssistantText += assistantEvent.delta;
		queueMatchingWatchJobs(currentAssistantText);
	});

	pi.on("message_end", async (event) => {
		if (!event || event.message?.role !== "assistant") return;
		const messageText = extractTextContent(event.message.content);
		if (messageText) {
			currentAssistantText = messageText;
			queueMatchingWatchJobs(messageText);
		}
	});

	pi.on("agent_end", async (_event, ctx) => {
		rememberContext(ctx);
		currentAssistantText = "";
		currentIdleGeneration += 1;
		queueIdleWatchJobs();
		updateUi(ctx);
		// CRITICAL: inside agent_end the agent's isStreaming flag is STILL true
		// (finishRun() runs in the finally block after all listeners settle, see
		// pi-coding-agent/packages/agent/src/agent.ts). If we dispatch here and
		// call pi.sendUserMessage(..., { deliverAs: "followUp" }) right now, the
		// message gets routed into agent.followUpQueue. But the agent loop has
		// already passed its getFollowUpMessages() check — it will exit without
		// draining the queue and our message sits there forever, visible as a
		// stuck "Follow-up: ..." in pi's UI. We'd also leak agentBusy=true and
		// block every subsequent pending job because no further agent_end fires.
		// Wait for the run to actually finish before draining.
		// ctx.waitForIdle() is only available on ExtensionCommandContext, not
		// ExtensionContext, so we poll isIdle() instead.
		let attempts = 0;
		const maxAttempts = 600; // ~30s at 50ms each
		while (!ctx.isIdle() && attempts < maxAttempts) {
			await new Promise((r) => setTimeout(r, 50));
			attempts++;
		}
		agentBusy = false;
		drainPendingJobs();
	});

	pi.on("session_shutdown", async (_event, ctx) => {
		rememberContext(ctx);
		clearAllTimers();
		stopUiTick();
		jobs.clear();
		watchJobs.clear();
		agentBusy = false;
		allPaused = false;
		currentAssistantText = "";
		currentIdleGeneration = 0;
		updateUi(ctx);
	});
}

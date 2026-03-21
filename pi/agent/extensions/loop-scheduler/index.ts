import { randomUUID } from "node:crypto";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";

const DEFAULT_INTERVAL_MS = 10 * 60 * 1000;
const MAX_JOBS = 50;

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

export default function loopSchedulerExtension(pi: ExtensionAPI): void {
	const jobs = new Map<string, LoopJob>();
	const timers = new Map<string, TimerHandle>();
	let lastCtx: ExtensionContext | undefined;
	let agentBusy = false;

	function rememberContext(ctx: ExtensionContext): void {
		lastCtx = ctx;
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
		description: "Schedule a recurring prompt: /loop 10m <prompt>, /loop list, /loop cancel <id|all>",
		handler: async (args, ctx) => {
			rememberContext(ctx);

			if (!ctx.hasUI) {
				writeCommandOutput("The /loop command requires an interactive or RPC session that stays open.");
				return;
			}

			const trimmed = args.trim();
			if (!trimmed || trimmed.toLowerCase() === "help") {
				notify("Usage: /loop <interval> <prompt> | /loop <prompt> | /loop list | /loop cancel <id|all>", "info", ctx);
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
		jobs.clear();
		agentBusy = false;
		updateUi(ctx);
	});
}

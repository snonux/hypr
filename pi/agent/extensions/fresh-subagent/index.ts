import { spawn, spawnSync } from "node:child_process";
import { createWriteStream } from "node:fs";
import { mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import type { AgentToolResult, AgentToolResultContent } from "@mariozechner/pi-agent-core";
import type { Message, TextContent } from "@mariozechner/pi-ai";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { Text } from "@mariozechner/pi-tui";
import { Type } from "@sinclair/typebox";

const CHILD_ENV_FLAG = "PI_FRESH_SUBAGENT_CHILD";
const LOG_BASENAME = "latest.log";
const HISTORY_SUFFIX = ".json";
const DEFAULT_HISTORY_LIMIT = 10;
const MAX_HISTORY_LIMIT = 50;
const MAX_RECENT_ACTIVITY = 12;
const MAX_WIDGET_LINES = 10;
const MAX_RENDER_PREVIEW_LINES = 8;
const MAX_ACTIVITY_LINE_LENGTH = 160;
const MAX_UPDATE_INTERVAL_MS = 150;
const HISTORY_PERSIST_INTERVAL_MS = 1000;

interface UsageStats {
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	cost: number;
	turns: number;
}

interface FreshSubagentResult {
	runId: string;
	prompt: string;
	model?: string;
	cwd: string;
	exitCode: number;
	stopReason?: string;
	errorMessage?: string;
	stderr: string;
	output: string;
	usage: UsageStats;
	logPath: string;
	metadataPath: string;
	latestLogPath: string;
	eventCount: number;
	lastStatus: string;
	currentTool?: string;
	recentActivity: string[];
}

interface SubagentHistoryEntry {
	runId: string;
	prompt: string;
	promptSummary: string;
	model?: string;
	cwd: string;
	startedAt: string;
	finishedAt?: string;
	active: boolean;
	exitCode?: number;
	stopReason?: string;
	errorMessage?: string;
	logPath: string;
	metadataPath: string;
	eventCount: number;
	lastStatus: string;
	currentTool?: string;
	outputPreview?: string;
}

interface SubagentLog {
	runId: string;
	logPath: string;
	metadataPath: string;
	latestLogPath: string;
	write(line: string): void;
	close(): Promise<void>;
}

interface RunFreshSubagentOptions {
	cwd: string;
	model?: string;
	tools?: string[];
	signal?: AbortSignal;
	onUpdate?: (partial: AgentToolResult<FreshSubagentResult>) => void;
	onState?: (details: FreshSubagentResult) => void;
}

let latestLogPathHint: string | undefined;
let activeLogPathHint: string | undefined;

function getProviderScopedModel(ctx: ExtensionContext): string | undefined {
	if (!ctx.model) return undefined;
	return `${ctx.model.provider}/${ctx.model.id}`;
}

function getLastAssistantText(messages: Message[]): string {
	for (let i = messages.length - 1; i >= 0; i--) {
		const message = messages[i];
		if (message.role !== "assistant") continue;
		const text = message.content
			.filter((part): part is TextContent => part.type === "text")
			.map((part) => part.text)
			.join("\n")
			.trim();
		if (text) return text;
	}
	return "";
}

function getSubagentLogDir(): string {
	const stateHome = process.env.XDG_STATE_HOME || path.join(homedir(), ".local", "state");
	return path.join(stateHome, "pi", "subagents");
}

function sanitizePromptForFile(prompt: string): string {
	const slug = prompt
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, "-")
		.replace(/^-+|-+$/g, "")
		.slice(0, 40);
	return slug || "subagent";
}

function makeRunId(prompt: string): string {
	const suffix = Math.random().toString(36).slice(2, 8);
	return `${timestampForFile()}-${sanitizePromptForFile(prompt)}-${suffix}`;
}

function timestampForFile(date = new Date()): string {
	const pad = (value: number) => String(value).padStart(2, "0");
	return [
		date.getFullYear(),
		pad(date.getMonth() + 1),
		pad(date.getDate()),
		"T",
		pad(date.getHours()),
		pad(date.getMinutes()),
		pad(date.getSeconds()),
	].join("");
}

async function writeHistoryEntry(entry: SubagentHistoryEntry): Promise<void> {
	await writeFile(entry.metadataPath, `${JSON.stringify(entry, null, 2)}\n`, "utf8");
}

async function readHistoryEntries(): Promise<SubagentHistoryEntry[]> {
	const dir = getSubagentLogDir();
	await mkdir(dir, { recursive: true });

	const files = await readdir(dir, { withFileTypes: true });
	const entries: SubagentHistoryEntry[] = [];

	for (const file of files) {
		if (!file.isFile() || !file.name.endsWith(HISTORY_SUFFIX)) continue;

		const metadataPath = path.join(dir, file.name);
		try {
			const raw = await readFile(metadataPath, "utf8");
			const parsed = JSON.parse(raw) as Partial<SubagentHistoryEntry>;
			if (!parsed.runId || !parsed.prompt || !parsed.logPath || !parsed.startedAt) continue;

			entries.push({
				runId: parsed.runId,
				prompt: parsed.prompt,
				promptSummary: parsed.promptSummary || summarizePrompt(parsed.prompt, 120),
				model: parsed.model,
				cwd: parsed.cwd || "",
				startedAt: parsed.startedAt,
				finishedAt: parsed.finishedAt,
				active: Boolean(parsed.active),
				exitCode: parsed.exitCode,
				stopReason: parsed.stopReason,
				errorMessage: parsed.errorMessage,
				logPath: parsed.logPath,
				metadataPath,
				eventCount: parsed.eventCount || 0,
				lastStatus: parsed.lastStatus || "unknown",
				currentTool: parsed.currentTool,
				outputPreview: parsed.outputPreview,
			});
		} catch {
			// Ignore malformed files so one bad history entry does not break browsing.
		}
	}

	return entries.sort((a, b) => {
		const aTime = Date.parse(a.startedAt) || 0;
		const bTime = Date.parse(b.startedAt) || 0;
		return bTime - aTime;
	});
}

function getHistoryStatus(entry: SubagentHistoryEntry): string {
	if (entry.active) {
		return entry.currentTool ? `active:${entry.currentTool}` : `active:${entry.lastStatus}`;
	}

	if (entry.stopReason === "aborted") return "aborted";
	if (entry.exitCode === 0 && entry.stopReason !== "error") return "done";
	return "error";
}

function normalizeHistorySelector(selector: string): string {
	return selector.trim();
}

async function resolveHistoryEntry(selector: string): Promise<{
	entry?: SubagentHistoryEntry;
	error?: string;
}> {
	const entries = await readHistoryEntries();
	if (entries.length === 0) {
		return { error: "No subagent history is available yet." };
	}

	const normalized = normalizeHistorySelector(selector || "latest");
	if (!normalized || normalized === "latest") {
		return { entry: entries[0] };
	}

	if (/^\d+$/.test(normalized)) {
		const index = Number(normalized);
		if (index >= 1 && index <= entries.length) return { entry: entries[index - 1] };
		return { error: `History index ${normalized} is out of range.` };
	}

	const exact = entries.find((entry) => entry.runId === normalized);
	if (exact) return { entry: exact };

	const matches = entries.filter((entry) => entry.runId.startsWith(normalized));
	if (matches.length === 1) return { entry: matches[0] };
	if (matches.length > 1) {
		return {
			error: `Selector '${normalized}' is ambiguous:\n${matches
				.slice(0, 8)
				.map((entry) => `- ${entry.runId}`)
				.join("\n")}`,
		};
	}

	return { error: `No subagent history entry matched '${normalized}'.` };
}

async function createSubagentLog(prompt: string): Promise<SubagentLog> {
	const dir = getSubagentLogDir();
	await mkdir(dir, { recursive: true });

	const runId = makeRunId(prompt);
	const logPath = path.join(dir, `${runId}.log`);
	const metadataPath = path.join(dir, `${runId}${HISTORY_SUFFIX}`);
	const latestLogPath = path.join(dir, LOG_BASENAME);
	const stream = createWriteStream(logPath, { flags: "a" });

	try {
		await rm(latestLogPath, { force: true });
		await symlink(path.basename(logPath), latestLogPath);
	} catch {
		// Best-effort only. The per-run log path still works even if the symlink fails.
	}

	const write = (line: string) => {
		const timestamp = new Date().toISOString();
		stream.write(`${timestamp} ${line}\n`);
	};

	return {
		runId,
		logPath,
		metadataPath,
		latestLogPath,
		write,
		close: () =>
			new Promise<void>((resolve) => {
				stream.end(resolve);
			}),
	};
}

function truncate(text: string, max: number): string {
	if (text.length <= max) return text;
	return `${text.slice(0, Math.max(0, max - 3))}...`;
}

function summarizePrompt(prompt: string, max = 80): string {
	return truncate(prompt.replace(/\s+/g, " ").trim(), max);
}

function summarizeValue(value: unknown, max = 120): string {
	if (value === undefined) return "";
	if (typeof value === "string") return truncate(value.replace(/\s+/g, " ").trim(), max);

	try {
		const json = JSON.stringify(value);
		return truncate(json, max);
	} catch {
		return truncate(String(value), max);
	}
}

function splitActivityLines(text: string): string[] {
	const collapsed = text.replace(/\r/g, "");
	const rawLines = collapsed.split("\n");
	const output: string[] = [];

	for (const raw of rawLines) {
		const line = raw.trimEnd();
		if (!line) continue;
		if (line.length <= MAX_ACTIVITY_LINE_LENGTH) {
			output.push(line);
			continue;
		}

		let remaining = line;
		while (remaining.length > MAX_ACTIVITY_LINE_LENGTH) {
			output.push(`${remaining.slice(0, MAX_ACTIVITY_LINE_LENGTH - 1)}…`);
			remaining = remaining.slice(MAX_ACTIVITY_LINE_LENGTH - 1);
		}
		if (remaining) output.push(remaining);
	}

	return output;
}

function extractContentText(content: unknown): string {
	if (!Array.isArray(content)) return "";

	return content
		.map((item) => {
			if (!item || typeof item !== "object") return "";
			const typedItem = item as { type?: string; text?: string };
			return typedItem.type === "text" && typeof typedItem.text === "string" ? typedItem.text : "";
		})
		.filter(Boolean)
		.join("\n");
}

function cloneResult(result: FreshSubagentResult): FreshSubagentResult {
	return {
		...result,
		recentActivity: [...result.recentActivity],
		usage: { ...result.usage },
	};
}

function renderRunningSummary(details: FreshSubagentResult): string {
	const lines = [
		`subagent: ${details.lastStatus || "running"}`,
		`run: ${details.runId}`,
		`log: ${details.logPath}`,
	];

	if (details.currentTool) lines.push(`tool: ${details.currentTool}`);

	if (details.recentActivity.length > 0) {
		lines.push("", ...details.recentActivity.slice(-MAX_RENDER_PREVIEW_LINES));
	}

	return lines.join("\n");
}

function buildWidgetLines(details: FreshSubagentResult): string[] {
	const lines = [
		`subagent: ${details.lastStatus || "running"}`,
		`run: ${details.runId}`,
		`log: ${details.latestLogPath}`,
	];

	if (details.currentTool) lines.push(`tool: ${details.currentTool}`);

	if (details.recentActivity.length > 0) {
		lines.push(...details.recentActivity.slice(-MAX_WIDGET_LINES));
	}

	return lines;
}

function renderSubagentSummary(details: FreshSubagentResult, expanded: boolean, theme: any): string {
	const status =
		details.exitCode === 0 && details.stopReason !== "error" && details.stopReason !== "aborted"
			? theme.fg("success", "✓")
			: theme.fg("error", "✗");
	const header = `${status} ${theme.fg("toolTitle", theme.bold("subagent"))}${
		details.model ? theme.fg("muted", ` ${details.model}`) : ""
	}`;

	const lines = [
		header,
		theme.fg("muted", `run: ${details.runId}`),
		theme.fg("muted", `cwd: ${details.cwd}`),
		theme.fg("muted", `log: ${details.logPath}`),
		theme.fg("muted", `meta: ${details.metadataPath}`),
		theme.fg("muted", `latest: ${details.latestLogPath}`),
		theme.fg("muted", `events: ${details.eventCount}`),
	];

	if (details.currentTool) lines.push(theme.fg("muted", `current tool: ${details.currentTool}`));

	if (expanded) {
		lines.push("", theme.fg("muted", "Prompt:"), details.prompt);
		lines.push("", theme.fg("muted", "Result:"), details.output || theme.fg("muted", "(no output)"));
		if (details.recentActivity.length > 0) {
			lines.push("", theme.fg("muted", "Recent Activity:"), ...details.recentActivity.slice(-MAX_RENDER_PREVIEW_LINES));
		}
	} else {
		const preview = details.output ? details.output.split("\n").slice(0, 5).join("\n") : "(no output)";
		lines.push("", preview);
	}

	if (details.errorMessage) lines.push("", theme.fg("error", `Error: ${details.errorMessage}`));
	if (details.stderr.trim()) lines.push("", theme.fg("dim", details.stderr.trim()));
	return lines.join("\n");
}

function formatHistoryEntries(entries: SubagentHistoryEntry[], limit: number): string {
	if (entries.length === 0) return "No subagent history is available yet.";

	return entries
		.slice(0, limit)
		.map((entry, index) => {
			const lines = [
				`${index + 1}. ${entry.runId} [${getHistoryStatus(entry)}]${entry.model ? ` ${entry.model}` : ""}`,
				`   started: ${entry.startedAt}`,
				`   prompt: ${entry.promptSummary}`,
				`   log: ${entry.logPath}`,
			];
			if (entry.outputPreview) lines.push(`   output: ${entry.outputPreview}`);
			return lines.join("\n");
		})
		.join("\n\n");
}

function formatHistoryDetails(entry: SubagentHistoryEntry): string {
	const lines = [
		`run: ${entry.runId}`,
		`status: ${getHistoryStatus(entry)}`,
		`started: ${entry.startedAt}`,
		`finished: ${entry.finishedAt || "(still running)"}`,
		`model: ${entry.model || "(session default)"}`,
		`cwd: ${entry.cwd}`,
		`prompt: ${entry.prompt}`,
		`log: ${entry.logPath}`,
		`metadata: ${entry.metadataPath}`,
		`tail: tail -f ${entry.logPath}`,
	];

	if (entry.outputPreview) lines.push(`output preview: ${entry.outputPreview}`);
	if (entry.errorMessage) lines.push(`error: ${entry.errorMessage}`);
	return lines.join("\n");
}

function quoteForShell(value: string): string {
	return `'${value.replace(/'/g, `'\"'\"'`)}'`;
}

function getEditorCommand(): string | undefined {
	return process.env.VISUAL || process.env.EDITOR;
}

async function openInExternalEditor(filePath: string, ctx: ExtensionCommandContext): Promise<{
	ok: boolean;
	message: string;
}> {
	const editorCmd = getEditorCommand();
	if (!editorCmd) {
		return { ok: false, message: "No editor configured. Set $VISUAL or $EDITOR." };
	}

	const command = `exec ${editorCmd} ${quoteForShell(filePath)}`;

	if (!ctx.hasUI) {
		const result = spawnSync("bash", ["-lc", command], {
			stdio: "inherit",
			env: process.env,
		});
		return result.status === 0
			? { ok: true, message: `Opened ${filePath} in ${editorCmd}` }
			: { ok: false, message: `Editor exited with code ${result.status ?? 1}` };
	}

	await ctx.waitForIdle();
	const exitCode = await ctx.ui.custom<number | null>((tui, _theme, _kb, done) => {
		tui.stop();
		process.stdout.write("\x1b[2J\x1b[H");

		const result = spawnSync("bash", ["-lc", command], {
			stdio: "inherit",
			env: process.env,
		});

		tui.start();
		tui.requestRender(true);
		done(result.status);

		return {
			render: () => [],
			invalidate: () => {},
		};
	});

	return exitCode === 0
		? { ok: true, message: `Opened ${filePath} in ${editorCmd}` }
		: { ok: false, message: `Editor exited with code ${exitCode ?? 1}` };
}

async function runFreshSubagent(prompt: string, options: RunFreshSubagentOptions): Promise<FreshSubagentResult> {
	const log = await createSubagentLog(prompt);
	latestLogPathHint = log.latestLogPath;
	activeLogPathHint = log.logPath;

	const args = ["--mode", "json", "-p", "--no-session"];
	if (options.model) args.push("--model", options.model);
	if (options.tools && options.tools.length > 0) args.push("--tools", options.tools.join(","));
	args.push(prompt);

	const result: FreshSubagentResult = {
		runId: log.runId,
		prompt,
		model: options.model,
		cwd: options.cwd,
		exitCode: 0,
		stderr: "",
		output: "",
		logPath: log.logPath,
		metadataPath: log.metadataPath,
		latestLogPath: log.latestLogPath,
		eventCount: 0,
		lastStatus: "starting",
		recentActivity: [],
		usage: {
			input: 0,
			output: 0,
			cacheRead: 0,
			cacheWrite: 0,
			cost: 0,
			turns: 0,
		},
	};

	const startedAt = new Date().toISOString();
	let finishedAt: string | undefined;
	let isFinished = false;
	let lastHistoryPersistAt = 0;
	let historyWriteChain: Promise<void> = Promise.resolve();

	const buildHistoryEntry = (): SubagentHistoryEntry => ({
		runId: result.runId,
		prompt: result.prompt,
		promptSummary: summarizePrompt(result.prompt, 120),
		model: result.model,
		cwd: result.cwd,
		startedAt,
		finishedAt,
		active: !isFinished,
		exitCode: result.exitCode,
		stopReason: result.stopReason,
		errorMessage: result.errorMessage,
		logPath: result.logPath,
		metadataPath: result.metadataPath,
		eventCount: result.eventCount,
		lastStatus: result.lastStatus,
		currentTool: result.currentTool,
		outputPreview: result.output || result.errorMessage ? summarizePrompt(result.output || result.errorMessage || "", 140) : undefined,
	});

	const persistHistory = async (force = false) => {
		const now = Date.now();
		if (!force && now - lastHistoryPersistAt < HISTORY_PERSIST_INTERVAL_MS) return;
		lastHistoryPersistAt = now;
		const entry = buildHistoryEntry();
		historyWriteChain = historyWriteChain
			.then(() => writeHistoryEntry(entry))
			.catch(() => {
				// Best-effort. Logging should not fail because the history sidecar write failed.
			});
		await historyWriteChain;
	};

	const messages: Message[] = [];
	const toolOutputById = new Map<string, string>();
	let assistantBuffer = "";
	let lastEmitAt = 0;
	let wasAborted = false;

	log.write(`[start] run=${result.runId}`);
	log.write(`[start] prompt=${summarizePrompt(prompt, 200)}`);
	log.write(`[start] cwd=${options.cwd}`);
	if (options.model) log.write(`[start] model=${options.model}`);
	await persistHistory(true);

	const pushActivity = (line: string) => {
		const lines = splitActivityLines(line);
		for (const entry of lines) {
			result.recentActivity.push(entry);
			if (result.recentActivity.length > MAX_RECENT_ACTIVITY) result.recentActivity.shift();
			log.write(entry);
		}
	};

	const flushAssistantBuffer = (force: boolean) => {
		let emitted = false;

		while (true) {
			const newlineIndex = assistantBuffer.indexOf("\n");
			if (newlineIndex >= 0) {
				const line = assistantBuffer.slice(0, newlineIndex);
				assistantBuffer = assistantBuffer.slice(newlineIndex + 1);
				if (line.trim()) pushActivity(`assistant> ${line}`);
				emitted = true;
				continue;
			}

			if (force && assistantBuffer.trim()) {
				pushActivity(`assistant> ${assistantBuffer}`);
				assistantBuffer = "";
				emitted = true;
				continue;
			}

			if (!force && assistantBuffer.length > 240) {
				pushActivity(`assistant> ${assistantBuffer.slice(0, 239)}…`);
				assistantBuffer = assistantBuffer.slice(239);
				emitted = true;
				continue;
			}

			break;
		}

		return emitted;
	};

	const emitUpdate = (force = false) => {
		const now = Date.now();
		if (!force && now - lastEmitAt < MAX_UPDATE_INTERVAL_MS) return;
		lastEmitAt = now;
		void persistHistory(force);

		const snapshot = cloneResult(result);
		options.onUpdate?.({
			content: [{ type: "text", text: renderRunningSummary(snapshot) }],
			details: snapshot,
		});
		options.onState?.(snapshot);
	};

	result.exitCode = await new Promise<number>((resolve) => {
		const proc = spawn("pi", args, {
			cwd: options.cwd,
			shell: false,
			stdio: ["ignore", "pipe", "pipe"],
			env: {
				...process.env,
				[CHILD_ENV_FLAG]: "1",
			},
		});

		let buffer = "";

		const processLine = (line: string) => {
			if (!line.trim()) return;

			let event: any;
			try {
				event = JSON.parse(line);
			} catch {
				log.write(`[raw] ${line}`);
				return;
			}

			result.eventCount++;

			switch (event.type) {
				case "agent_start":
					result.lastStatus = "agent started";
					pushActivity("[agent] started");
					emitUpdate(true);
					return;
				case "agent_end":
					flushAssistantBuffer(true);
					result.lastStatus = "agent finished";
					pushActivity("[agent] finished");
					emitUpdate(true);
					return;
				case "turn_start":
					result.lastStatus = "turn started";
					emitUpdate();
					return;
				case "turn_end":
					result.lastStatus = "turn finished";
					emitUpdate();
					return;
				case "message_update": {
					if (event.message?.role !== "assistant" || !event.assistantMessageEvent) return;
					const assistantEvent = event.assistantMessageEvent;

					switch (assistantEvent.type) {
						case "text_delta":
							if (typeof assistantEvent.delta === "string") {
								result.lastStatus = "assistant streaming";
								assistantBuffer += assistantEvent.delta;
								flushAssistantBuffer(false);
								emitUpdate();
							}
							return;
						case "text_end":
							result.lastStatus = "assistant text complete";
							if (flushAssistantBuffer(true)) emitUpdate(true);
							return;
						case "thinking_start":
							result.lastStatus = "assistant thinking";
							emitUpdate();
							return;
						case "toolcall_start":
							result.lastStatus = "assistant preparing tool call";
							emitUpdate();
							return;
						case "toolcall_end": {
							const toolCall = assistantEvent.toolCall || {};
							const toolName = toolCall.toolName || toolCall.name || "tool";
							const argsPreview = summarizeValue(toolCall.args || toolCall.input);
							result.lastStatus = `assistant requested ${toolName}`;
							pushActivity(argsPreview ? `[plan] ${toolName} ${argsPreview}` : `[plan] ${toolName}`);
							emitUpdate(true);
							return;
						}
						case "done":
							result.lastStatus = assistantEvent.reason ? `assistant ${assistantEvent.reason}` : "assistant done";
							emitUpdate(true);
							return;
						case "error":
							result.lastStatus = assistantEvent.reason ? `assistant ${assistantEvent.reason}` : "assistant error";
							emitUpdate(true);
							return;
						default:
							return;
					}
				}
				case "message_end": {
					const message = event.message as Message | undefined;
					if (!message) return;

					messages.push(message);
					result.output = getLastAssistantText(messages);

					if (message.role === "assistant") {
						flushAssistantBuffer(true);
						result.usage.turns++;
						const usage = message.usage;
						if (usage) {
							result.usage.input += usage.input || 0;
							result.usage.output += usage.output || 0;
							result.usage.cacheRead += usage.cacheRead || 0;
							result.usage.cacheWrite += usage.cacheWrite || 0;
							result.usage.cost += usage.cost?.total || 0;
						}
						if (!result.model && message.model) result.model = message.model;
						if (message.stopReason) result.stopReason = message.stopReason;
						if (message.errorMessage) result.errorMessage = message.errorMessage;
					}

					emitUpdate(true);
					return;
				}
				case "tool_execution_start": {
					flushAssistantBuffer(true);
					result.currentTool = event.toolName;
					result.lastStatus = `tool ${event.toolName} running`;
					const argsPreview = summarizeValue(event.args);
					pushActivity(argsPreview ? `[tool:start] ${event.toolName} ${argsPreview}` : `[tool:start] ${event.toolName}`);
					emitUpdate(true);
					return;
				}
				case "tool_execution_update": {
					flushAssistantBuffer(true);
					result.currentTool = event.toolName;
					result.lastStatus = `tool ${event.toolName} running`;

					const partialText = extractContentText(event.partialResult?.content);
					if (partialText) {
						const previous = toolOutputById.get(event.toolCallId) || "";
						const delta = partialText.startsWith(previous) ? partialText.slice(previous.length) : partialText;
						toolOutputById.set(event.toolCallId, partialText);

						if (delta.trim()) {
							for (const line of splitActivityLines(delta)) {
								pushActivity(`[tool:${event.toolName}] ${line}`);
							}
						}
					}

					emitUpdate();
					return;
				}
				case "tool_execution_end": {
					flushAssistantBuffer(true);
					const toolName = event.toolName || result.currentTool || "tool";
					const finalText = extractContentText(event.result?.content);
					const previous = toolOutputById.get(event.toolCallId) || "";
					const delta = finalText.startsWith(previous) ? finalText.slice(previous.length) : finalText;
					if (delta.trim()) {
						for (const line of splitActivityLines(delta)) {
							pushActivity(`[tool:${toolName}] ${line}`);
						}
					}

					result.lastStatus = event.isError ? `tool ${toolName} failed` : `tool ${toolName} done`;
					pushActivity(event.isError ? `[tool:end] ${toolName} error` : `[tool:end] ${toolName} done`);
					result.currentTool = undefined;
					emitUpdate(true);
					return;
				}
				case "auto_retry_start":
					result.lastStatus = `retry ${event.attempt}/${event.maxAttempts}`;
					pushActivity(`[retry] ${event.attempt}/${event.maxAttempts} ${event.errorMessage || ""}`.trim());
					emitUpdate(true);
					return;
				case "auto_retry_end":
					result.lastStatus = event.success ? "retry recovered" : "retry failed";
					emitUpdate(true);
					return;
				default:
					return;
			}
		};

		proc.stdout.on("data", (data) => {
			buffer += data.toString();
			const lines = buffer.split("\n");
			buffer = lines.pop() || "";
			for (const line of lines) processLine(line);
		});

		proc.stderr.on("data", (data) => {
			const chunk = data.toString();
			result.stderr += chunk;
			for (const line of splitActivityLines(chunk)) {
				log.write(`[stderr] ${line}`);
			}
		});

		proc.on("close", (code) => {
			if (buffer.trim()) processLine(buffer);
			resolve(code ?? 0);
		});

		proc.on("error", (err) => {
			result.errorMessage = err.message;
			resolve(1);
		});

		if (options.signal) {
			const killProc = () => {
				wasAborted = true;
				proc.kill("SIGTERM");
				setTimeout(() => {
					if (!proc.killed) proc.kill("SIGKILL");
				}, 5000);
			};

			if (options.signal.aborted) killProc();
			else options.signal.addEventListener("abort", killProc, { once: true });
		}
	});

	if (wasAborted) {
		result.stopReason = "aborted";
		result.errorMessage = "Fresh subagent was aborted";
		result.lastStatus = "aborted";
		pushActivity("[agent] aborted");
	}

	result.output ||= getLastAssistantText(messages);
	log.write(`[finish] exit=${result.exitCode} stop=${result.stopReason || "unknown"}`);
	if (result.errorMessage) log.write(`[finish] error=${result.errorMessage}`);

	finishedAt = new Date().toISOString();
	isFinished = true;
	await persistHistory(true);
	await log.close();
	activeLogPathHint = undefined;
	emitUpdate(true);
	await historyWriteChain;
	return result;
}

function getLogInfoText(entry?: SubagentHistoryEntry): string {
	if (entry) return formatHistoryDetails(entry);

	const latestPath = latestLogPathHint || path.join(getSubagentLogDir(), LOG_BASENAME);
	const lines = [`latest log: ${latestPath}`, `tail -f ${latestPath}`];
	if (activeLogPathHint) lines.push(`active run: ${activeLogPathHint}`);
	return lines.join("\n");
}

function createSlashCommandHandler(watch: boolean) {
	return async (args: string, ctx: ExtensionContext, pi: ExtensionAPI) => {
		const prompt = args.trim();
		if (!prompt) {
			ctx.ui.notify("Usage: /subagent <prompt>", "warning");
			return;
		}

		const statusId = "fresh-subagent";
		const widgetId = "fresh-subagent-watch";
		const applyUiState = (details: FreshSubagentResult) => {
			if (!ctx.hasUI || !watch) return;
			const statusText = details.currentTool
				? `subagent: ${details.currentTool}`
				: `subagent: ${details.lastStatus}`;
			ctx.ui.setStatus(statusId, ctx.ui.theme.fg("warning", statusText));
			ctx.ui.setWidget(widgetId, buildWidgetLines(details), { placement: "belowEditor" });
		};

		if (ctx.hasUI) {
			ctx.ui.setStatus(statusId, ctx.ui.theme.fg("warning", "subagent: starting"));
			if (watch) ctx.ui.setWidget(widgetId, ["subagent: starting"], { placement: "belowEditor" });
		}

		try {
			const details = await runFreshSubagent(prompt, {
				cwd: ctx.cwd,
				model: getProviderScopedModel(ctx),
				onState: applyUiState,
			});

			if (!ctx.hasUI) {
				const text = details.output || details.errorMessage || details.stderr || "(no output)";
				if (text) process.stdout.write(`${text}\n`);
				process.stdout.write(`${getLogInfoText()}\n`);
				return;
			}

			pi.sendMessage(
				{
					customType: "fresh-subagent-result",
					content: details.output || "(no output)",
					display: true,
					details,
				},
				{ triggerTurn: false },
			);
		} finally {
			if (ctx.hasUI) {
				ctx.ui.setStatus(statusId, undefined);
				ctx.ui.setWidget(widgetId, undefined);
			}
		}
	};
}

export default function freshSubagentExtension(pi: ExtensionAPI): void {
	if (process.env[CHILD_ENV_FLAG] === "1") return;

	const params = Type.Object({
		prompt: Type.String({ description: "Prompt to run in a fresh-context subagent" }),
		model: Type.Optional(Type.String({ description: "Optional model override. Defaults to the current session model." })),
		cwd: Type.Optional(Type.String({ description: "Working directory for the subagent process" })),
		tools: Type.Optional(Type.Array(Type.String(), { description: "Optional tool allowlist for the subagent process" })),
	});

	pi.registerTool({
		name: "subagent",
		label: "Subagent",
		description: "Spawn a fresh-context subagent with a prompt and return its final answer. Each run is logged and added to subagent history.",
		promptSnippet: "Delegate a self-contained task to a fresh-context subagent and get its result back",
		promptGuidelines: [
			"Use this tool for any self-contained side task that benefits from a clean context, such as review, research, summarization, or focused implementation checks.",
			"Pass a complete prompt with enough context for the subagent to succeed independently, because it starts with a fresh session.",
			"Each subagent run is logged to its own file. Tell the user about /subagent-history or /subagent-open if they want the full transcript later.",
		],
		parameters: params,

		async execute(_toolCallId, params, signal, onUpdate, ctx) {
			const details = await runFreshSubagent(params.prompt, {
				cwd: params.cwd ?? ctx.cwd,
				model: params.model ?? getProviderScopedModel(ctx),
				tools: params.tools,
				signal,
				onUpdate,
			});

			const content: AgentToolResultContent[] = [{ type: "text", text: details.output || "(no output)" }];
			const isError = details.exitCode !== 0 || details.stopReason === "error" || details.stopReason === "aborted";

			if (isError) {
				const text = details.errorMessage || details.stderr || details.output || "Fresh subagent failed.";
				return {
					content: [{ type: "text", text }],
					details,
					isError: true,
				};
			}

			return { content, details };
		},

		renderCall(args, theme) {
			const preview = summarizePrompt(args.prompt);
			return new Text(
				`${theme.fg("toolTitle", theme.bold("subagent"))}\n  ${theme.fg("dim", preview)}`,
				0,
				0,
			);
		},

		renderResult(result, { expanded }, theme) {
			const details = result.details as FreshSubagentResult | undefined;
			if (!details) {
				const text = result.content[0];
				return new Text(text?.type === "text" ? text.text : "(no output)", 0, 0);
			}
			return new Text(renderSubagentSummary(details, expanded, theme), 0, 0);
		},
	});

	const watchedSubagentHandler = createSlashCommandHandler(true);

	pi.registerCommand("subagent", {
		description: "Run a fresh-context subagent with live status, widget updates, and durable run history",
		handler: async (args, ctx) => watchedSubagentHandler(args, ctx, pi),
	});

	pi.registerCommand("subagent-watch", {
		description: "Alias for /subagent with live watched output",
		handler: async (args, ctx) => watchedSubagentHandler(args, ctx, pi),
	});

	pi.registerCommand("subagent-session", {
		description: "Launch a visible fresh-context Pi session for a subagent task",
		handler: async (args, ctx) => {
			const prompt = args.trim();
			if (!prompt) {
				ctx.ui.notify("Usage: /subagent-session <prompt>", "warning");
				return;
			}

			if (!ctx.hasUI) {
				process.stdout.write("/subagent-session requires interactive mode.\n");
				return;
			}

			await ctx.waitForIdle();
			const currentSession = ctx.sessionManager.getSessionFile();
			const result = await ctx.newSession({
				parentSession: currentSession,
			});

			if (result.cancelled) {
				ctx.ui.notify("Subagent session launch cancelled", "info");
				return;
			}

			pi.setSessionName(`subagent: ${summarizePrompt(prompt, 40)}`);
			pi.sendUserMessage(prompt);
		},
	});

	pi.registerCommand("subagent-log", {
		description: "Show the log path and metadata for the latest or selected subagent run",
		handler: async (args, ctx) => {
			const selector = args.trim();
			const resolved = selector ? await resolveHistoryEntry(selector) : {};
			const text = resolved.entry ? getLogInfoText(resolved.entry) : resolved.error || getLogInfoText();

			if (!ctx.hasUI) {
				process.stdout.write(`${text}\n`);
				return;
			}

			pi.sendMessage(
				{
					customType: "fresh-subagent-log-info",
					content: text,
					display: true,
					details: { text },
				},
				{ triggerTurn: false },
			);
		},
	});

	pi.registerCommand("subagent-history", {
		description: "List recent fresh-subagent runs so you can browse their full logs later",
		handler: async (args, ctx) => {
			const requested = Number(args.trim() || DEFAULT_HISTORY_LIMIT);
			const limit = Number.isFinite(requested)
				? Math.max(1, Math.min(MAX_HISTORY_LIMIT, requested))
				: DEFAULT_HISTORY_LIMIT;
			const text = formatHistoryEntries(await readHistoryEntries(), limit);

			if (!ctx.hasUI) {
				process.stdout.write(`${text}\n`);
				return;
			}

			pi.sendMessage(
				{
					customType: "fresh-subagent-history",
					content: text,
					display: true,
					details: { text },
				},
				{ triggerTurn: false },
			);
		},
	});

	pi.registerCommand("subagent-open", {
		description: "Open a subagent log in $VISUAL/$EDITOR. Usage: /subagent-open [latest|index|run-id-prefix]",
		handler: async (args, ctx) => {
			const selector = args.trim() || "latest";
			const resolved = await resolveHistoryEntry(selector);
			if (!resolved.entry) {
				const text = resolved.error || `No subagent history entry matched '${selector}'.`;
				if (!ctx.hasUI) process.stdout.write(`${text}\n`);
				else ctx.ui.notify(text, "warning");
				return;
			}

			const opened = await openInExternalEditor(resolved.entry.logPath, ctx);
			if (!ctx.hasUI) {
				process.stdout.write(`${opened.message}\n`);
				return;
			}

			ctx.ui.notify(opened.message, opened.ok ? "info" : "error");
		},
	});

	pi.registerMessageRenderer("fresh-subagent-result", (message, { expanded }, theme) => {
		return new Text(renderSubagentSummary(message.details as FreshSubagentResult, expanded, theme), 0, 0);
	});

	pi.registerMessageRenderer("fresh-subagent-log-info", (message) => {
		return new Text(String(message.content || message.details?.text || getLogInfoText()), 0, 0);
	});

	pi.registerMessageRenderer("fresh-subagent-history", (message) => {
		return new Text(String(message.content || message.details?.text || "No subagent history is available yet."), 0, 0);
	});
}

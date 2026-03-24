import { existsSync } from "node:fs";
import type { AgentMessage } from "@mariozechner/pi-agent-core";
import type { AssistantMessage, TextContent } from "@mariozechner/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { Key } from "@mariozechner/pi-tui";
import {
	containsRawTaskCommand,
	dedupePlanItems,
	extractPlanItems,
	formatTaskDetails,
	formatTaskLine,
	isSafePlanCommand,
	normalizeTaskText,
	parseCreatedTaskUuid,
	stripAnsi,
	type AgentTask,
	type PlanItem,
} from "./utils.js";

const PLAN_MODE_TOOLS = ["read", "bash", "grep", "find", "ls", "write", "edit"];
const STATE_TYPE = "agent-plan-mode";

interface PlanModeState {
	enabled: boolean;
	executing: boolean;
	planItems: PlanItem[];
	createdTaskUuids: string[];
	normalTools: string[];
	// Path of the plan file created or opened in the current plan mode session.
	activePlanFile?: string;
}

interface WorkOnTasksArgs {
	strategy: string;
	maxTasks?: number;
}

function escapeRegExp(value: string): string {
	return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function normalizeCommandText(command: string): string {
	return command.trim().replace(/\s+/g, " ");
}

function isMutatingAskCommand(command: string): boolean {
	return /\b(add|annotate|append|delete|denotate|done|log|modify|prepend|start|stop|undo)\b/.test(command);
}

function repeatedCurrentTaskLookupKey(command: string, currentTaskUuid?: string): string | undefined {
	if (!currentTaskUuid) return undefined;

	const normalized = normalizeCommandText(command);
	if (!/^ask(?:\s|$)/.test(normalized)) return undefined;
	if (isMutatingAskCommand(normalized)) return undefined;

	const uuidPattern = new RegExp(`(?:^|\\s)["']?uuid:${escapeRegExp(currentTaskUuid)}["']?(?:\\s|$)`);
	if (!uuidPattern.test(normalized)) return undefined;

	return normalized;
}

function malformedAskReason(command: string): string | undefined {
	const normalized = normalizeCommandText(command);
	if (!/^ask(?:\s|$)/.test(normalized)) return undefined;

	if (/\bagent-task-management\b/.test(normalized)) {
		return "The 'ask' command uses subcommand syntax. Do not pass the skill name or natural-language workflow text to it. Use concrete ask subcommands such as 'ask list start.any:', 'ask ready', 'ask info uuid:<uuid>', 'ask annotate uuid:<uuid> \"note\"', 'ask modify uuid:<uuid> priority:H', or 'ask done uuid:<uuid>'.";
	}

	return undefined;
}

function parseSelectorAndPayload(rawArgs: string): { selector: string; payload: string } | undefined {
	const separator = rawArgs.indexOf("::");
	if (separator === -1) return undefined;

	const selector = rawArgs.slice(0, separator).trim();
	const payload = rawArgs.slice(separator + 2).trim();
	if (!selector || !payload) return undefined;

	return { selector, payload };
}

function splitShellWords(input: string): string[] {
	const words: string[] = [];
	const pattern = /"((?:\\.|[^"])*)"|'((?:\\.|[^'])*)'|(\S+)/g;

	for (const match of input.matchAll(pattern)) {
		const value = match[1] ?? match[2] ?? match[3];
		if (!value) continue;
		words.push(value.replace(/\\(["'\\])/g, "$1"));
	}

	return words;
}

function isAssistantMessage(message: AgentMessage): message is AssistantMessage {
	return message.role === "assistant" && Array.isArray(message.content);
}

function getTextContent(message: AssistantMessage): string {
	return message.content
		.filter((block): block is TextContent => block.type === "text")
		.map((block) => block.text)
		.join("\n");
}

function parseWorkOnTasksArgs(rawArgs: string): WorkOnTasksArgs {
	const parts = rawArgs
		.trim()
		.split(/\s+/)
		.filter(Boolean);

	let maxTasks: number | undefined;
	if (parts.length > 0 && /^\d+$/.test(parts[parts.length - 1] ?? "")) {
		const parsed = Number(parts.pop());
		if (Number.isFinite(parsed) && parsed > 0) {
			maxTasks = parsed;
		}
	}

	return {
		strategy: parts.join(" ") || "highest-impact",
		maxTasks,
	};
}

export default function agentPlanModeExtension(pi: ExtensionAPI): void {
	let planModeEnabled = false;
	let executionMode = false;
	let planItems: PlanItem[] = [];
	let createdTaskUuids: string[] = [];
	let normalTools: string[] = [];
	let executionTaskUuid: string | undefined;
	let repeatedTaskLookups = new Set<string>();
	// Stored so the mode:deactivate listener can update UI without a ctx parameter.
	let lastCtx: ExtensionContext | undefined;
	// Plan file created or opened in the current plan mode session; undefined until first write.
	let activePlanFile: string | undefined;

	pi.registerFlag("plan", {
		description: "Start in plan mode (read-only exploration)",
		type: "boolean",
		default: false,
	});

	async function runCommand(
		command: string,
		args: string[],
		ctx: ExtensionContext,
		signal?: AbortSignal,
	): Promise<{ stdout: string; stderr: string; code: number }> {
		const result = await pi.exec(command, args, {
			cwd: ctx.cwd,
			signal,
			timeout: 30_000,
		});
		return {
			stdout: stripAnsi(result.stdout ?? ""),
			stderr: stripAnsi(result.stderr ?? ""),
			code: result.code,
		};
	}

	async function runAsk(
		args: string[],
		ctx: ExtensionContext,
		signal?: AbortSignal,
	): Promise<{ stdout: string; stderr: string; code: number }> {
		return runCommand("ask", ["--json", ...args], ctx, signal);
	}

	async function getProjectName(ctx: ExtensionContext): Promise<string> {
		const command =
			'basename -s .git "$(git remote get-url origin 2>/dev/null)" 2>/dev/null || basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"';
		const result = await runCommand("bash", ["-lc", command], ctx);
		return result.stdout.trim() || "unknown";
	}

	async function loadTasks(args: string[], ctx: ExtensionContext, signal?: AbortSignal): Promise<AgentTask[]> {
		const result = await runAsk(args, ctx, signal);
		if (result.code !== 0 || !result.stdout.trim()) return [];

		try {
			const parsed = JSON.parse(result.stdout) as AgentTask[];
			return Array.isArray(parsed) ? parsed : [];
		} catch {
			return [];
		}
	}

	async function getStartedTasks(ctx: ExtensionContext, signal?: AbortSignal): Promise<AgentTask[]> {
		return loadTasks(["list", "start.any:"], ctx, signal);
	}

	async function getReadyTasks(ctx: ExtensionContext, signal?: AbortSignal): Promise<AgentTask[]> {
		const tasks = await loadTasks(["ready"], ctx, signal);
		return tasks.filter((task) => !task.start);
	}

	async function getTaskByUuid(uuid: string, ctx: ExtensionContext, signal?: AbortSignal): Promise<AgentTask | undefined> {
		const tasks = await loadTasks(["info", `uuid:${uuid}`], ctx, signal);
		return tasks[0];
	}

	async function getCurrentTask(ctx: ExtensionContext, signal?: AbortSignal): Promise<AgentTask | undefined> {
		const started = await getStartedTasks(ctx, signal);
		if (started.length > 0) {
			return started[0];
		}

		const ready = await getReadyTasks(ctx, signal);
		return ready[0];
	}

	async function annotateTask(uuid: string, note: string, ctx: ExtensionContext, signal?: AbortSignal): Promise<void> {
		await runAsk([`uuid:${uuid}`, "annotate", note], ctx, signal);
	}

	async function startTask(uuid: string, ctx: ExtensionContext, signal?: AbortSignal): Promise<void> {
		await runAsk([`uuid:${uuid}`, "start"], ctx, signal);
	}

	async function getTaskById(id: string, ctx: ExtensionContext, signal?: AbortSignal): Promise<AgentTask | undefined> {
		const tasks = await loadTasks(["info", String(id)], ctx, signal);
		return tasks[0];
	}

	async function createTask(
		description: string,
		ctx: ExtensionContext,
		options?: { dependsOn?: string; annotation?: string; signal?: AbortSignal },
	): Promise<string | undefined> {
		const args = ["add"];
		if (options?.dependsOn) args.push(`dep:add:${options.dependsOn}`);
		args.push(description);

		const result = await runAsk(args, ctx, options?.signal);
		if (result.code !== 0) return undefined;

		const createdId = parseCreatedTaskUuid(result.stdout);
		if (!createdId) return undefined;

		const task = await getTaskById(createdId, ctx, options?.signal);
		const uuid = task?.uuid;
		if (uuid && options?.annotation) {
			await annotateTask(uuid, options.annotation, ctx, options.signal);
		}
		return uuid;
	}

	async function syncPlanToAsk(
		mode: "sequential" | "independent",
		ctx: ExtensionContext,
		signal?: AbortSignal,
	): Promise<{ created: string[]; reused: string[] }> {
		const existingTasks = await loadTasks(["list", "status:pending"], ctx, signal);
		const existingByDescription = new Map<string, AgentTask>();
		for (const task of existingTasks) {
			existingByDescription.set(normalizeTaskText(task.description), task);
		}

		const created: string[] = [];
		const reused: string[] = [];
		let previousUuid: string | undefined;

		for (const item of planItems) {
			const key = normalizeTaskText(item.text);
			const existing = existingByDescription.get(key);
			if (existing) {
				item.uuid = existing.uuid;
				reused.push(existing.uuid);
				if (mode === "sequential") previousUuid = existing.uuid;
				continue;
			}

			const annotation = `Pi plan mode step ${item.step}. See ${plansDir}/ for overall context`;
			const uuid = await createTask(item.text, ctx, {
				dependsOn: mode === "sequential" ? previousUuid : undefined,
				annotation,
				signal,
			});

			if (!uuid) continue;

			item.uuid = uuid;
			created.push(uuid);
			existingByDescription.set(key, {
				uuid,
				description: item.text,
				status: "pending",
			});
			if (mode === "sequential") previousUuid = uuid;
		}

		createdTaskUuids = dedupePlanItems(planItems)
			.map((item) => item.uuid)
			.filter((uuid): uuid is string => Boolean(uuid));
		persistState();
		return { created, reused };
	}

	async function buildTaskOverview(ctx: ExtensionContext, signal?: AbortSignal): Promise<string> {
		const projectName = await getProjectName(ctx);
		const started = await getStartedTasks(ctx, signal);
		const ready = await getReadyTasks(ctx, signal);

		const lines = [`Project: ${projectName}`];

		if (started.length > 0) {
			lines.push("", "Started tasks:");
			for (const task of started.slice(0, 5)) {
				lines.push(`- ${formatTaskLine(task)} (${task.uuid})`);
			}
		} else {
			lines.push("", "Started tasks: none");
		}

		if (ready.length > 0) {
			lines.push("", "Next READY tasks:");
			for (const task of ready.slice(0, 5)) {
				lines.push(`- ${formatTaskLine(task)} (${task.uuid})`);
			}
		} else {
			lines.push("", "Next READY tasks: none");
		}

		return lines.join("\n");
	}

	function persistState(): void {
		pi.appendEntry<PlanModeState>(STATE_TYPE, {
			enabled: planModeEnabled,
			executing: executionMode,
			planItems,
			createdTaskUuids,
			normalTools,
			activePlanFile,
		});
	}

	async function updateStatus(ctx: ExtensionContext): Promise<void> {
		if (planModeEnabled) {
			ctx.ui.setStatus("task-plan-mode", ctx.ui.theme.fg("warning", "⏸ plan"));
			ctx.ui.setWidget("task-plan-mode", undefined);
			return;
		}

		if (!executionMode) {
			ctx.ui.setStatus("task-plan-mode", undefined);
			ctx.ui.setWidget("task-plan-mode", undefined);
			return;
		}

		const currentTask = await getCurrentTask(ctx);
		if (!currentTask) {
			executionTaskUuid = undefined;
			ctx.ui.setStatus("task-plan-mode", ctx.ui.theme.fg("muted", "task: none"));
			ctx.ui.setWidget("task-plan-mode", undefined);
			return;
		}

		executionTaskUuid = currentTask.uuid;
		ctx.ui.setStatus(
			"task-plan-mode",
			ctx.ui.theme.fg("accent", `task ${currentTask.priority ?? "-"} ${currentTask.id ?? "?"}`),
		);
		ctx.ui.setWidget("task-plan-mode", [
			ctx.ui.theme.fg("accent", "Agent plan focus"),
			`${currentTask.start ? "▶" : "○"} ${currentTask.description}`,
			`${ctx.ui.theme.fg("muted", "uuid")} ${currentTask.uuid}`,
		]);
	}

	async function setPlanModeEnabled(enabled: boolean, ctx: ExtensionContext): Promise<void> {
		if (enabled === planModeEnabled) return;

		planModeEnabled = enabled;
		executionMode = false;

		if (enabled) {
			normalTools = pi.getActiveTools();
			pi.setActiveTools(PLAN_MODE_TOOLS);
			executionTaskUuid = undefined;
			activePlanFile = undefined; // start fresh; no plan file committed to yet
			repeatedTaskLookups.clear();
			ctx.ui.notify(`Plan mode enabled. Tools: ${PLAN_MODE_TOOLS.join(", ")}`);
		} else {
			pi.setActiveTools(normalTools);
			ctx.ui.notify("Plan mode disabled. Restored previous tools.");
		}

		persistState();
		await updateStatus(ctx);
	}

	async function enterPlanMode(ctx: ExtensionContext): Promise<void> {
		lastCtx = ctx;
		if (planModeEnabled) {
			ctx.ui.notify("Plan mode is already enabled.", "info");
			return;
		}
		pi.events.emit("mode:deactivate", { except: "agent-plan-mode" });
		await setPlanModeEnabled(true, ctx);
	}

	async function exitPlanMode(ctx: ExtensionContext): Promise<void> {
		lastCtx = ctx;
		if (!planModeEnabled) {
			ctx.ui.notify("Plan mode is not enabled.", "info");
			return;
		}
		await setPlanModeEnabled(false, ctx);
	}

	async function exitExecutionMode(ctx: ExtensionContext): Promise<void> {
		if (!executionMode) {
			ctx.ui.notify("Focus mode is not enabled.", "info");
			return;
		}

		executionMode = false;
		executionTaskUuid = undefined;
		repeatedTaskLookups.clear();
		pi.setActiveTools(normalTools);
		persistState();
		await updateStatus(ctx);
		ctx.ui.notify("Focus mode disabled.", "info");
	}

	async function createTasksFromPlan(
		mode: "sequential" | "independent",
		ctx: ExtensionContext,
	): Promise<void> {
		if (planItems.length === 0) {
			ctx.ui.notify("No extracted plan available. Enable /plan and generate a plan first.", "warning");
			return;
		}

		const { created, reused } = await syncPlanToAsk(mode, ctx);
		ctx.ui.notify(
			`Task sync complete. Created ${created.length}, reused ${reused.length} existing task(s).`,
			"info",
		);
		await updateStatus(ctx);
	}

	async function replaceTaskDescription(selector: string, description: string, ctx: ExtensionContext): Promise<void> {
		const result = await runAsk([selector, "modify", description], ctx);
		if (result.code !== 0) {
			ctx.ui.notify(result.stderr || result.stdout || "Task update failed.", "error");
			return;
		}

		ctx.ui.notify(result.stdout.trim() || "Task description updated.", "info");
	}

	async function modifyTask(selector: string, modsText: string, ctx: ExtensionContext): Promise<void> {
		const mods = splitShellWords(modsText);
		if (mods.length === 0) {
			ctx.ui.notify("No modify arguments provided.", "warning");
			return;
		}

		const result = await runAsk([selector, "modify", ...mods], ctx);
		if (result.code !== 0) {
			ctx.ui.notify(result.stderr || result.stdout || "Task modify failed.", "error");
			return;
		}

		ctx.ui.notify(result.stdout.trim() || "Task modified.", "info");
	}

	async function focusCurrentTask(runNow: boolean, ctx: ExtensionContext): Promise<void> {
		const started = await getStartedTasks(ctx);
		let task = started[0];

		if (!task) {
			const ready = await getReadyTasks(ctx);
			task = ready[0];
			if (!task) {
				ctx.ui.notify("No started or READY task found for this project.", "warning");
				return;
			}
			await startTask(task.uuid, ctx);
			task = await getTaskByUuid(task.uuid, ctx);
		}

		if (!task) {
			ctx.ui.notify("Could not resolve the active task.", "error");
			return;
		}

		executionMode = true;
		planModeEnabled = false;
		pi.setActiveTools(normalTools);
		executionTaskUuid = task.uuid;
		repeatedTaskLookups.clear();
		persistState();
		await updateStatus(ctx);

		const projectName = await getProjectName(ctx);
		ctx.ui.notify(`Focused task ${task.id ?? "?"}: ${task.description}`, "info");

		if (runNow) {
			pi.sendUserMessage(
				`Work on the current task for project ${projectName}. Use ask for all task operations. Current task UUID: ${task.uuid}.`,
			);
		}
	}

	pi.registerCommand("plan", {
		description: "Enter plan mode (read-only exploration)",
		handler: async (_args, ctx) => enterPlanMode(ctx),
	});

	pi.registerCommand("plan-exit", {
		description: "Leave plan mode and restore normal tools",
		handler: async (_args, ctx) => exitPlanMode(ctx),
	});

	pi.registerCommand("tasks", {
		description: "Show started and READY tasks for this project",
		handler: async (_args, ctx) => {
			ctx.ui.notify(await buildTaskOverview(ctx), "info");
		},
	});

	pi.registerCommand("plan-create-tasks", {
		description: "Create tasks from the last extracted plan",
		handler: async (args, ctx) => {
			const mode = args.trim().toLowerCase() === "independent" ? "independent" : "sequential";
			await createTasksFromPlan(mode, ctx);
		},
	});

	pi.registerCommand("task-sync", {
		description: "Legacy alias for /plan-create-tasks",
		handler: async (args, ctx) => {
			const mode = args.trim().toLowerCase() === "independent" ? "independent" : "sequential";
			await createTasksFromPlan(mode, ctx);
		},
	});

	pi.registerCommand("task-next", {
		description: "Focus the started task, or start the next READY task",
		handler: async (args, ctx) => {
			await focusCurrentTask(args.trim().toLowerCase() === "run", ctx);
		},
	});

	pi.registerCommand("task-exit", {
		description: "Leave focus mode",
		handler: async (_args, ctx) => {
			await exitExecutionMode(ctx);
		},
	});

	pi.registerCommand("task-unfocus", {
		description: "Alias for /task-exit",
		handler: async (_args, ctx) => {
			await exitExecutionMode(ctx);
		},
	});

	pi.registerCommand("task-update", {
		description: "Replace a task description: /task-update <selector> :: <new description>",
		handler: async (args, ctx) => {
			const parsed = parseSelectorAndPayload(args);
			if (!parsed) {
				ctx.ui.notify("Usage: /task-update <selector> :: <new description>", "warning");
				return;
			}
			await replaceTaskDescription(parsed.selector, parsed.payload, ctx);
		},
	});

	pi.registerCommand("task-modify", {
		description: "Run ask modify args: /task-modify <selector> :: <mods>",
		handler: async (args, ctx) => {
			const parsed = parseSelectorAndPayload(args);
			if (!parsed) {
				ctx.ui.notify("Usage: /task-modify <selector> :: <mods>", "warning");
				return;
			}
			await modifyTask(parsed.selector, parsed.payload, ctx);
		},
	});

	pi.registerCommand("work-on-tasks", {
		description: "Run the task workflow for this repo",
		handler: async (args, ctx) => {
			const parsed = parseWorkOnTasksArgs(args);
			await focusCurrentTask(false, ctx);

			const currentTask = await getCurrentTask(ctx);
			if (!currentTask) {
				ctx.ui.notify("No started or READY task found for this project.", "warning");
				return;
			}

			const projectName = await getProjectName(ctx);
			const maxTasksText = parsed.maxTasks ? String(parsed.maxTasks) : "none";

			pi.sendUserMessage(`Use the task workflow rules below for the current git project.

Project: ${projectName}
Selection strategy: ${parsed.strategy}
Max tasks: ${maxTasksText}

Current focused task:
${formatTaskDetails(currentTask)}

Workflow:
1. Treat the current focused task above as the already-selected starting point for this run.
2. Only use ask to load project-scoped tasks when the current task is missing, blocked, completed, or you are ready to pick the next task.
3. Use priority first, then urgency, as the stable ordering rule. Use the requested selection strategy only as a tie-breaker or framing hint.
4. Start and execute the chosen task.
5. Annotate meaningful implementation progress back to the task using UUID selectors.
6. Self-review your own changes before any completion step.
7. After self-review, if the subagent tool is available, use it to run an independent fresh-context review of the completed changes.
8. Address all review findings, repeat the independent review if needed, and only then commit all changes.
9. Mark the task complete only when implementation, tests, self-review, independent subagent review, and required fixes are complete.
10. Immediately return to started tasks, then READY tasks, and continue until there are no actionable tasks, max_tasks is reached, or a hard blocker is encountered.
11. If blocked, annotate the blocker to the task and stop.

Rules:
- Never use raw task; always use ask.
- 'ask' is a CLI tool for task management, not a natural-language interface and not a skill runner.
- Valid examples: 'ask ready', 'ask list start.any:', 'ask info uuid:<uuid>', 'ask annotate uuid:<uuid> \"note\"', 'ask modify uuid:<uuid> priority:H', 'ask done uuid:<uuid>'.
- Invalid examples: 'ask agent-task-management ...', 'ask list tasks', 'ask show task 298', or any other natural-language phrasing.
- Scope all work to project:${projectName} +agent tasks only.
- Use UUIDs for all long-lived references.
- Do not repeat the same ask lookup for the current task unless task state may have changed or required information is still missing.
- After one task lookup, move into repo inspection, implementation, testing, review, or annotation before refreshing task data again.
- Do not ask the user to choose a task unless there is a real ambiguity or risk.
- Keep working autonomously until the workflow reaches a stop condition.

Begin with the current focused task now. Do not re-check the task list immediately just to confirm the same task again.`, {
				deliverAs: ctx.isIdle() ? undefined : "steer",
			});
		},
	});

	pi.registerShortcut(Key.ctrlAlt("p"), {
		description: "Toggle plan mode",
		handler: async (ctx) => togglePlanMode(ctx),
	});

	// Resolve the plans directory once; expandable via HOME env var.
	const plansDir = (process.env.HOME ?? "~").replace(/\/$/, "") + "/.pi/plans";

	pi.on("tool_call", async (event) => {
		if (planModeEnabled) {
			if (event.toolName === "write" || event.toolName === "edit") {
				const filePath = String(event.input.file_path ?? event.input.filePath ?? event.input.path ?? "");
				// Only allow writes inside ~/.pi/plans — never inside the project directory.
				const normalised = filePath.replace(/\/$/, "");
				if (!normalised.startsWith(plansDir + "/") && normalised !== plansDir) {
					return {
						block: true,
						reason: `Plan mode only allows writing files inside ${plansDir}.\nFile: ${filePath}\nCreate the directory with: mkdir -p ${plansDir}`,
					};
				}

				// Guard against overwriting an unrelated existing plan file.
				// A file that already exists on disk is only allowed if it is the
				// active plan file for this session.  New files are always allowed
				// and become the active plan file.
				if (existsSync(normalised)) {
					if (activePlanFile && normalised !== activePlanFile) {
						return {
							block: true,
							reason: `Plan mode blocked overwriting an unrelated existing plan file.\nFile: ${filePath}\nActive plan for this session: ${activePlanFile}\nCreate a new file with a different name if this is a separate plan.`,
						};
					}
					// First write to an existing file in this session — adopt it as active.
					activePlanFile = normalised;
					persistState();
				} else {
					// New file: adopt it as the active plan for this session.
					activePlanFile = normalised;
					persistState();
				}

				return;
			}
		}

		if (!executionMode) {
			if (event.toolName !== "bash") return;
		} else if (event.toolName !== "bash") {
			repeatedTaskLookups.clear();
			return;
		}

		const command = String(event.input.command ?? "");
		const repeatedLookupKey = executionMode ? repeatedCurrentTaskLookupKey(command, executionTaskUuid) : undefined;
		if (executionMode && repeatedLookupKey) {
			if (repeatedTaskLookups.has(repeatedLookupKey)) {
				return {
					block: true,
					reason:
						"Repeated lookup of the same current task was blocked. Use the task details already in context and move to code inspection, implementation, tests, review, or an annotation before refreshing the same task again.",
				};
			}
			repeatedTaskLookups.add(repeatedLookupKey);
		} else if (executionMode) {
			repeatedTaskLookups.clear();
		}

		const malformedAsk = malformedAskReason(command);
		if (malformedAsk) {
			return {
				block: true,
				reason: malformedAsk,
			};
		}

		if (containsRawTaskCommand(command)) {
			return {
				block: true,
				reason: "Use 'ask ...' for all task operations. Raw 'task' is blocked by agent-plan-mode.",
			};
		}

		if (planModeEnabled && !isSafePlanCommand(command)) {
			return {
				block: true,
				reason: `Plan mode blocks mutating shell commands.\nCommand: ${command}`,
			};
		}
	});

	pi.on("context", async (event) => {
		return {
			messages: event.messages.filter((message) => {
				const candidate = message as AgentMessage & { customType?: string };
				if (!planModeEnabled && candidate.customType === "agent-plan-mode-context") return false;
				if (!executionMode && candidate.customType === "agent-execution-mode-context") return false;
				return true;
			}),
		};
	});

	pi.on("before_agent_start", async (_event, ctx) => {
		const projectName = await getProjectName(ctx);

		if (planModeEnabled) {
			const overview = await buildTaskOverview(ctx);
			return {
				message: {
					customType: "agent-plan-mode-context",
					content: `[AGENT PLAN MODE ACTIVE]
You are in planning mode for project ${projectName}.

Rules:
- Use read, bash, grep, find, ls for exploration.
- For task operations, always use 'ask ...'. Never use raw 'task'. All ask operations are allowed (add, annotate, modify, done, start, stop, etc.).
- You may write or edit files only inside ${plansDir}. Create that directory first if it does not exist: mkdir -p ${plansDir}
- Write one plan markdown file there (e.g. ${plansDir}/<project>.md) describing the overall picture, goals, and task structure.
- Do NOT write any files inside the current project directory.
- Do NOT overwrite an existing plan file that belongs to a different plan. If this is a new, unrelated plan, create a new file with a distinct name.
- Once you write or open a plan file, it becomes the active plan for this session. Stick to that file unless explicitly asked to switch.
- For every task created with 'ask add', immediately annotate it with a reference to the plan file: 'ask annotate <uuid> "See ${plansDir}/<project>.md for overall context"'.
- Read existing started tasks first; if none, inspect the next READY tasks.
- Avoid duplicating tasks that already exist.

Current task overview:
${overview}

Create a concise numbered plan under a "Plan:" header. Each step must be a single actionable task:

Plan:
1. First actionable task
2. Second actionable task
3. Third actionable task`,
					display: false,
				},
			};
		}

		if (executionMode) {
			const currentTask = await getCurrentTask(ctx);
			if (!currentTask) return;
			executionTaskUuid = currentTask.uuid;

			return {
				message: {
					customType: "agent-execution-mode-context",
					content: `[AGENT EXECUTION MODE]
Project: ${projectName}

Use the task workflow rules below:
- Use 'ask ...' for all task operations. Never use raw 'task'.
- 'ask' is a CLI tool. It does not understand the skill name or natural-language requests.
- Valid examples: 'ask list start.any:', 'ask ready', 'ask info uuid:<uuid>', 'ask annotate uuid:<uuid> \"note\"', 'ask modify uuid:<uuid> priority:H', 'ask done uuid:<uuid>'.
- Invalid examples: 'ask agent-task-management ...', 'ask list tasks', 'ask show task 298', or any other natural-language phrasing.
- Continue an already-started task before starting a new one.
- Use UUIDs for long-lived references and follow-up commands.
- The current task below is already the selected task for this turn. Do not immediately query the same UUID again unless required details are missing or task state changed.
- After one task lookup, move to repo inspection or implementation work before refreshing task data again.
- Do not mark a task done until implementation, tests, and commit are complete.
- Annotate meaningful progress back to the task with 'ask uuid:<uuid> annotate ...' when appropriate.
- Self-review first, then if the subagent tool is available use it for an independent fresh-context review before the task is marked done.

Current task:
${formatTaskDetails(currentTask)}`,
					display: false,
				},
			};
		}
	});

	pi.on("turn_end", async (_event, ctx) => {
		repeatedTaskLookups.clear();
		if (executionMode) {
			await updateStatus(ctx);
		}
	});

	pi.on("agent_end", async (event, ctx) => {
		repeatedTaskLookups.clear();
		if (executionMode) {
			await updateStatus(ctx);
			return;
		}

		if (!planModeEnabled) return;

		const lastAssistant = [...event.messages].reverse().find(isAssistantMessage);
		if (!lastAssistant) return;

		planItems = dedupePlanItems(extractPlanItems(getTextContent(lastAssistant)));
		persistState();

		if (planItems.length === 0) return;

		const todoListText = planItems.map((item) => `${item.step}. ${item.text}`).join("\n");
		pi.sendMessage(
			{
				customType: "agent-plan-items",
				content: `**Extracted task plan (${planItems.length} steps):**\n\n${todoListText}`,
				display: true,
			},
			{ triggerTurn: false },
		);

		if (ctx.hasUI) {
			ctx.ui.notify("Plan extracted. Run /plan-create-tasks or /plan-exit when ready.", "info");
		}
	});

	pi.events.on("mode:deactivate", (data) => {
		const { except } = data as { except: string };
		if (except === "agent-plan-mode" || !planModeEnabled) return;
		planModeEnabled = false;
		executionMode = false;
		executionTaskUuid = undefined;
		repeatedTaskLookups.clear();
		pi.setActiveTools(normalTools.length > 0 ? normalTools : ["read", "bash", "edit", "write"]);
		persistState();
		// Update the status bar and notify the user; lastCtx is set whenever a command runs.
		if (lastCtx) {
			lastCtx.ui.notify("Plan mode disabled (another mode activated).", "info");
			void updateStatus(lastCtx);
		}
	});

	pi.on("session_start", async (_event, ctx) => {
		lastCtx = ctx;
		if (pi.getFlag("plan") === true) {
			planModeEnabled = true;
		}

		const entries = ctx.sessionManager.getEntries();
		const planStateEntry = entries
			.filter((entry: { type: string; customType?: string }) => entry.type === "custom" && entry.customType === STATE_TYPE)
			.pop() as { data?: PlanModeState } | undefined;

		if (planStateEntry?.data) {
			planModeEnabled = planStateEntry.data.enabled ?? planModeEnabled;
			executionMode = planStateEntry.data.executing ?? executionMode;
			planItems = planStateEntry.data.planItems ?? planItems;
			createdTaskUuids = planStateEntry.data.createdTaskUuids ?? createdTaskUuids;
			normalTools = planStateEntry.data.normalTools?.length ? planStateEntry.data.normalTools : normalTools;
			activePlanFile = planStateEntry.data.activePlanFile ?? activePlanFile;
		} else {
			normalTools = pi.getActiveTools();
		}
		repeatedTaskLookups.clear();

		if (planModeEnabled) {
			pi.setActiveTools(PLAN_MODE_TOOLS);
		}

		await updateStatus(ctx);
	});
}

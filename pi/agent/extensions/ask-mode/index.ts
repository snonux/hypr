import type { AgentMessage } from "@mariozechner/pi-agent-core";
import type { TextContent } from "@mariozechner/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { isSafeAskModeCommand } from "./utils.js";

const ASK_MODE_TOOLS = ["read", "bash", "grep", "find", "ls"];
const STATE_TYPE = "ask-mode";
const CONTEXT_TYPE = "ask-mode-context";

interface AskModeState {
	enabled: boolean;
	normalTools: string[];
}

function hasAskModeMarker(message: AgentMessage): boolean {
	const customMessage = message as AgentMessage & { customType?: string };
	if (customMessage.customType === CONTEXT_TYPE) return true;

	if (message.role !== "user") return false;
	if (typeof message.content === "string") return message.content.includes("[ASK MODE ACTIVE]");
	if (!Array.isArray(message.content)) return false;

	return message.content.some(
		(block) => block.type === "text" && (block as TextContent).text?.includes("[ASK MODE ACTIVE]"),
	);
}

export default function askModeExtension(pi: ExtensionAPI): void {
	let askModeEnabled = false;
	let normalTools: string[] = [];

	function persistState(): void {
		pi.appendEntry<AskModeState>(STATE_TYPE, {
			enabled: askModeEnabled,
			normalTools,
		});
	}

	function updateStatus(ctx: ExtensionContext): void {
		if (!askModeEnabled) {
			ctx.ui.setStatus("ask-mode", undefined);
			ctx.ui.setWidget("ask-mode", undefined);
			return;
		}

		ctx.ui.setStatus("ask-mode", ctx.ui.theme.fg("warning", "⏸ ask"));
		ctx.ui.setWidget("ask-mode", [
			ctx.ui.theme.fg("warning", "Ask mode"),
			"Exploration only",
			"Files are read-only",
			"Bash is restricted to safe read-only commands",
		]);
	}

	function enterAskMode(ctx: ExtensionContext): void {
		if (askModeEnabled) {
			updateStatus(ctx);
			return;
		}

		normalTools = pi.getActiveTools();
		askModeEnabled = true;
		pi.setActiveTools(ASK_MODE_TOOLS);
		ctx.ui.notify(`Ask mode enabled. Tools: ${ASK_MODE_TOOLS.join(", ")}`, "info");
		updateStatus(ctx);
		persistState();
	}

	function exitAskMode(ctx: ExtensionContext): void {
		if (!askModeEnabled) {
			ctx.ui.notify("Ask mode is not active.", "info");
			updateStatus(ctx);
			return;
		}

		askModeEnabled = false;
		pi.setActiveTools(normalTools.length > 0 ? normalTools : ["read", "bash", "edit", "write"]);
		ctx.ui.notify("Ask mode disabled. Previous tools restored.", "info");
		updateStatus(ctx);
		persistState();
	}

	pi.registerCommand("ask", {
		description: "Enter ask mode for exploration-only work. Optional prompt sends a question immediately.",
		handler: async (args, ctx) => {
			const prompt = args.trim();
			enterAskMode(ctx);
			if (prompt) {
				pi.sendUserMessage(prompt);
				if (!ctx.hasUI) {
					await ctx.waitForIdle();
				}
			}
		},
	});

	pi.registerCommand("ask-exit", {
		description: "Leave ask mode and restore the previous tool set",
		handler: async (_args, ctx) => exitAskMode(ctx),
	});

	pi.registerCommand("ask-status", {
		description: "Show whether ask mode is active",
		handler: async (_args, ctx) => {
			const message = askModeEnabled
				? `Ask mode active. Tools: ${ASK_MODE_TOOLS.join(", ")}`
				: "Ask mode is not active.";
			if (!ctx.hasUI) {
				process.stdout.write(`${message}\n`);
				return;
			}
			ctx.ui.notify(message, "info");
		},
	});

	pi.on("tool_call", async (event) => {
		if (!askModeEnabled) return;

		if (!ASK_MODE_TOOLS.includes(event.toolName)) {
			return {
				block: true,
				reason: `Ask mode: tool "${event.toolName}" is disabled. Use /ask-exit before modifying files or using other tools.`,
			};
		}

		if (event.toolName === "bash") {
			const command = String(event.input.command ?? "");
			if (!isSafeAskModeCommand(command)) {
				return {
					block: true,
					reason: `Ask mode: bash command blocked (not recognized as safe read-only exploration).\nCommand: ${command}`,
				};
			}
		}
	});

	pi.on("context", async (event) => {
		if (askModeEnabled) return;
		return {
			messages: event.messages.filter((message) => !hasAskModeMarker(message as AgentMessage)),
		};
	});

	pi.on("before_agent_start", async () => {
		if (!askModeEnabled) return;

		return {
			message: {
				customType: CONTEXT_TYPE,
				content: `[ASK MODE ACTIVE]
You are in ask mode: exploration only.

Rules:
- Do not modify files.
- Do not use edit or write tools.
- Use read, grep, find, ls, and only safe read-only bash commands.
- Inspect, explain, compare, summarize, and answer questions.
- If a requested action would require a file change, say so explicitly instead of doing it.

Focus on observation and analysis, not implementation.`,
				display: false,
			},
		};
	});

	pi.on("session_start", async (_event, ctx) => {
		const entries = ctx.sessionManager.getEntries();
		const latestState = entries
			.filter((entry: { type: string; customType?: string }) => entry.type === "custom" && entry.customType === STATE_TYPE)
			.pop() as { data?: AskModeState } | undefined;

		if (latestState?.data) {
			askModeEnabled = latestState.data.enabled ?? askModeEnabled;
			normalTools = latestState.data.normalTools ?? normalTools;
		}

		if (askModeEnabled) {
			pi.setActiveTools(ASK_MODE_TOOLS);
		}

		updateStatus(ctx);
	});
}

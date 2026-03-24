import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";

export default function (pi: ExtensionAPI) {
	// Capture ctx so the tool can call ctx.reload() directly, avoiding a
	// follow-up user message that would re-trigger the AI and cause a reload loop.
	let lastCtx: ExtensionContext | undefined;

	pi.on("session_start", async (_event, ctx) => {
		lastCtx = ctx;
	});

	pi.registerCommand("reload-runtime", {
		description: "Reload extensions, skills, prompts, and themes",
		handler: async (_args, ctx) => {
			lastCtx = ctx;
			await ctx.reload();
			return;
		},
	});

	pi.registerTool({
		name: "reload_runtime",
		label: "Reload Runtime",
		// Explicit single-use guidance prevents the AI from calling this in a loop.
		description: "Reload extensions, skills, prompts, and themes. Call this once after editing extension files. Do not call it again in the same turn.",
		parameters: Type.Object({}),
		async execute() {
			if (lastCtx) {
				// Direct reload via ctx avoids injecting a follow-up user message,
				// which would start a new AI turn and risk a reload loop.
				await lastCtx.reload();
				return {
					content: [{ type: "text", text: "Runtime reloaded." }],
					details: {},
				};
			}
			// Fallback if ctx is not yet available (should not happen in practice).
			pi.sendUserMessage("/reload-runtime", { deliverAs: "followUp" });
			return {
				content: [{ type: "text", text: "Queued /reload-runtime as a follow-up command." }],
				details: {},
			};
		},
	});
}

import { complete, type Message, type TextContent, type UserMessage } from "@mariozechner/pi-ai";
import {
	convertToLlm,
	type ExtensionAPI,
	type ExtensionCommandContext,
	type SessionEntry,
} from "@mariozechner/pi-coding-agent";

const SYSTEM_PROMPT = `You are answering a side question for the user.

Rules:
- Use the supplied conversation context if it is relevant.
- Answer the side question directly and concisely.
- Do not use tools.
- Do not invent facts that are not supported by the supplied context.
- If the answer is not available from the supplied conversation context, say so plainly.
- Keep the answer short by default unless the user explicitly asks for depth.`;

function extractResponseText(message: Message): string {
	return message.content
		.filter((block): block is TextContent => block.type === "text")
		.map((block) => block.text)
		.join("\n")
		.trim();
}

function getConversationMessages(ctx: ExtensionCommandContext): Message[] {
	const branch = ctx.sessionManager.getBranch();
	return branch
		.filter((entry): entry is SessionEntry & { type: "message" } => entry.type === "message")
		.map((entry) => entry.message);
}

async function runBtw(question: string, ctx: ExtensionCommandContext): Promise<string> {
	if (!ctx.model) {
		throw new Error("No model selected.");
	}

	const branchMessages = getConversationMessages(ctx);
	const llmMessages = convertToLlm(branchMessages);
	const apiKey = await ctx.modelRegistry.getApiKey(ctx.model);
	const userMessage: UserMessage = {
		role: "user",
		content: [{ type: "text", text: question }],
		timestamp: Date.now(),
	};

	const response = await complete(
		ctx.model,
		{
			systemPrompt: SYSTEM_PROMPT,
			messages: [...llmMessages, userMessage],
		},
		{ apiKey },
	);

	if (response.stopReason === "aborted") {
		throw new Error("Cancelled.");
	}

	return extractResponseText(response) || "(no answer)";
}

const BTW_WIDGET = "btw";

export default function btwExtension(pi: ExtensionAPI): void {
	pi.registerCommand("btw", {
		description: "Ask a quick side question without blocking — answer appears in a widget",
		handler: async (args, ctx) => {
			const trimmed = args.trim();

			// /btw close — dismiss the answer widget.
			if (/^close$/i.test(trimmed)) {
				if (ctx.hasUI) ctx.ui.setWidget(BTW_WIDGET, undefined);
				return;
			}

			const question = trimmed;
			if (!question) {
				const usage = "Usage: /btw <side question>  |  /btw close";
				if (!ctx.hasUI) process.stdout.write(`${usage}\n`);
				else ctx.ui.notify(usage, "warning");
				return;
			}

			if (!ctx.model) {
				const error = "No model selected.";
				if (!ctx.hasUI) process.stdout.write(`${error}\n`);
				else ctx.ui.notify(error, "error");
				return;
			}

			// Non-UI path: blocking is fine in a pipe/CLI context.
			if (!ctx.hasUI) {
				try {
					const answer = await runBtw(question, ctx);
					process.stdout.write(`${answer}\n`);
				} catch (error) {
					const text = error instanceof Error ? error.message : String(error);
					process.stdout.write(`${text}\n`);
				}
				return;
			}

			// Non-blocking UI path: show a loading widget immediately and return so
			// the user can keep typing while the LLM answers in the background.
			ctx.ui.setWidget(
				BTW_WIDGET,
				[ctx.ui.theme.fg("accent", "BTW"), `⟳ ${ctx.ui.theme.fg("muted", question)}`, "  asking…"],
				{ placement: "belowEditor" },
			);

			void runBtw(question, ctx)
				.then((answer) => {
					ctx.ui.setWidget(
						BTW_WIDGET,
						[
							ctx.ui.theme.fg("accent", "BTW") + ctx.ui.theme.fg("muted", "  /btw close to dismiss"),
							` Q: ${question}`,
							...answer.split("\n").map((line) => ` ${line}`),
						],
						{ placement: "belowEditor" },
					);
				})
				.catch((error) => {
					const text = error instanceof Error ? error.message : String(error);
					ctx.ui.setWidget(BTW_WIDGET, undefined);
					ctx.ui.notify(`BTW failed: ${text}`, "error");
				});
		},
	});
}

import { complete, type Message, type TextContent, type UserMessage } from "@mariozechner/pi-ai";
import {
	BorderedLoader,
	convertToLlm,
	type ExtensionAPI,
	type ExtensionCommandContext,
	type SessionEntry,
	type Theme,
} from "@mariozechner/pi-coding-agent";
import { matchesKey, truncateToWidth, visibleWidth } from "@mariozechner/pi-tui";

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

function wrapParagraph(text: string, width: number): string[] {
	if (width <= 1) return [text];
	if (!text.trim()) return [""];

	const words = text.split(/\s+/).filter(Boolean);
	if (words.length === 0) return [""];

	const lines: string[] = [];
	let current = "";

	for (const word of words) {
		const next = current ? `${current} ${word}` : word;
		if (visibleWidth(next) <= width) {
			current = next;
			continue;
		}

		if (current) lines.push(current);

		if (visibleWidth(word) <= width) {
			current = word;
			continue;
		}

		let remainder = word;
		while (visibleWidth(remainder) > width) {
			lines.push(truncateToWidth(remainder, width, ""));
			remainder = remainder.slice(lines[lines.length - 1]!.length);
		}
		current = remainder;
	}

	if (current) lines.push(current);
	return lines.length > 0 ? lines : [""];
}

function wrapText(text: string, width: number): string[] {
	return text.split(/\r?\n/).flatMap((line) => wrapParagraph(line, width));
}

class BtwOverlay {
	constructor(
		private readonly theme: Theme,
		private readonly question: string,
		private readonly answer: string,
		private readonly done: () => void,
	) {}

	handleInput(data: string): void {
		if (matchesKey(data, "escape") || matchesKey(data, "return") || data === " " || data === "\r") {
			this.done();
		}
	}

	render(width: number): string[] {
		const innerWidth = Math.max(20, width - 2);
		const contentWidth = Math.max(10, innerWidth - 2);
		const lines: string[] = [];

		const pad = (text: string) => {
			const visible = visibleWidth(text);
			return text + " ".repeat(Math.max(0, innerWidth - visible));
		};

		const row = (text = "") => `${this.theme.fg("border", "│")}${pad(text)}${this.theme.fg("border", "│")}`;
		const addWrappedSection = (label: string, value: string) => {
			lines.push(row(` ${this.theme.fg("accent", label)}`));
			for (const wrapped of wrapText(value || "(no answer)", contentWidth)) {
				lines.push(row(` ${wrapped}`));
			}
			lines.push(row());
		};

		lines.push(this.theme.fg("border", `╭${"─".repeat(innerWidth)}╮`));
		lines.push(row(` ${this.theme.fg("accent", "BTW")}${this.theme.fg("muted", "  Side question")}`));
		lines.push(row());
		addWrappedSection("Question", this.question);
		addWrappedSection("Answer", this.answer || "(no answer)");
		lines.push(row(this.theme.fg("dim", " Esc, Enter, or Space to close")));
		lines.push(this.theme.fg("border", `╰${"─".repeat(innerWidth)}╯`));

		return lines;
	}

	invalidate(): void {}
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

export default function btwExtension(pi: ExtensionAPI): void {
	pi.registerCommand("btw", {
		description: "Ask a quick side question without adding it to the conversation",
		handler: async (args, ctx) => {
			const question = args.trim();
			if (!question) {
				const usage = "Usage: /btw <side question>";
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

			const answer = await ctx.ui.custom<string | null>(
				(tui, theme, _kb, done) => {
					const loader = new BorderedLoader(tui, theme, `Asking BTW using ${ctx.model!.id}...`);
					loader.onAbort = () => done(null);

					runBtw(question, ctx)
						.then(done)
						.catch((error) => {
							const text = error instanceof Error ? error.message : String(error);
							done(`BTW failed: ${text}`);
						});

					return loader;
				},
				{
					overlay: true,
					overlayOptions: {
						width: "50%",
						minWidth: 50,
						maxHeight: "80%",
						anchor: "right-center",
						offsetX: -1,
					},
				},
			);

			if (answer === null) {
				ctx.ui.notify("BTW cancelled.", "info");
				return;
			}

			await ctx.ui.custom<void>(
				(_tui, theme, _kb, done) => new BtwOverlay(theme, question, answer, done),
				{
					overlay: true,
					overlayOptions: {
						width: "55%",
						minWidth: 56,
						maxHeight: "85%",
						anchor: "right-center",
						offsetX: -1,
					},
				},
			);
		},
	});
}

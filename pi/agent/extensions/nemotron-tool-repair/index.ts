import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
	createAssistantMessageEventStream,
	type AssistantMessage,
	type Context,
	type Model,
	type OpenAICompletionsCompat,
	type SimpleStreamOptions,
	streamSimpleOpenAICompletions,
	type TextContent,
	type ThinkingContent,
	type Tool,
	type ToolCall,
	type Usage,
} from "@mariozechner/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";

const CUSTOM_API = "hyperstack-openai-completions-repaired";
const TARGET_PROVIDERS = new Set(["hyperstack1", "hyperstack2"]);
const NEMOTRON_MODEL_PATTERN = /NVIDIA-Nemotron-3-Super/i;
const MODELS_JSON_PATH = path.resolve(
	path.dirname(fileURLToPath(import.meta.url)),
	"..",
	"..",
	"models.json",
);

const NEMOTRON_TOOL_DISCIPLINE = `
Additional tool-use discipline for this model:
- If a tool is needed, call it immediately.
- Do not narrate that you are about to call a tool.
- Do not emit example tool-call markup or pseudo-tool syntax for the user to read.
- Emit at most one tool invocation at a time, then wait for the tool result.
- After a tool result, continue from that result instead of restating the plan.
`.trim();

interface FileModelConfig {
	id: string;
	name: string;
	reasoning: boolean;
	input: ("text" | "image")[];
	cost: { input: number; output: number; cacheRead: number; cacheWrite: number };
	contextWindow: number;
	maxTokens: number;
	compat?: OpenAICompletionsCompat;
}

interface FileProviderConfig {
	baseUrl: string;
	apiKey: string;
	api?: string;
	compat?: OpenAICompletionsCompat;
	models: FileModelConfig[];
}

interface FileConfig {
	providers: Record<string, FileProviderConfig>;
}

type AssistantBlock = TextContent | ThinkingContent | ToolCall;

function isNemotronModel(model: Pick<Model<any>, "id"> | undefined): boolean {
	return Boolean(model && NEMOTRON_MODEL_PATTERN.test(model.id));
}

function withRepairedCompat(compat?: OpenAICompletionsCompat): OpenAICompletionsCompat {
	return {
		...(compat || {}),
		supportsStrictMode: false,
	};
}

function loadProviderConfig(): FileConfig {
	const raw = readFileSync(MODELS_JSON_PATH, "utf8");
	return JSON.parse(raw) as FileConfig;
}

function cloneUsage(usage: Usage): Usage {
	return {
		input: usage.input,
		output: usage.output,
		cacheRead: usage.cacheRead,
		cacheWrite: usage.cacheWrite,
		totalTokens: usage.totalTokens,
		cost: {
			input: usage.cost.input,
			output: usage.cost.output,
			cacheRead: usage.cost.cacheRead,
			cacheWrite: usage.cost.cacheWrite,
			total: usage.cost.total,
		},
	};
}

function cloneBlock(block: AssistantBlock): AssistantBlock {
	switch (block.type) {
		case "text":
			return { ...block };
		case "thinking":
			return { ...block };
		case "toolCall":
			return {
				...block,
				arguments: { ...block.arguments },
			};
	}
}

function buildStreamingAssistantMessage(source: AssistantMessage): AssistantMessage {
	return {
		...source,
		content: [],
		usage: cloneUsage(source.usage),
	};
}

function emitAssistantMessage(
	stream: ReturnType<typeof createAssistantMessageEventStream>,
	source: AssistantMessage,
): void {
	const output = buildStreamingAssistantMessage(source);
	stream.push({ type: "start", partial: output });

	for (const sourceBlock of source.content) {
		if (sourceBlock.type === "text") {
			const block: TextContent = { type: "text", text: "" };
			output.content.push(block);
			const contentIndex = output.content.length - 1;
			stream.push({ type: "text_start", contentIndex, partial: output });
			if (sourceBlock.text) {
				block.text = sourceBlock.text;
				stream.push({
					type: "text_delta",
					contentIndex,
					delta: sourceBlock.text,
					partial: output,
				});
			}
			stream.push({
				type: "text_end",
				contentIndex,
				content: sourceBlock.text,
				partial: output,
			});
			continue;
		}

		if (sourceBlock.type === "thinking") {
			const block: ThinkingContent = {
				type: "thinking",
				thinking: "",
				thinkingSignature: sourceBlock.thinkingSignature,
				redacted: sourceBlock.redacted,
			};
			output.content.push(block);
			const contentIndex = output.content.length - 1;
			stream.push({ type: "thinking_start", contentIndex, partial: output });
			if (sourceBlock.thinking) {
				block.thinking = sourceBlock.thinking;
				stream.push({
					type: "thinking_delta",
					contentIndex,
					delta: sourceBlock.thinking,
					partial: output,
				});
			}
			stream.push({
				type: "thinking_end",
				contentIndex,
				content: sourceBlock.thinking,
				partial: output,
			});
			continue;
		}

		const block: ToolCall = {
			type: "toolCall",
			id: sourceBlock.id,
			name: sourceBlock.name,
			arguments: {},
			thoughtSignature: sourceBlock.thoughtSignature,
		};
		output.content.push(block);
		const contentIndex = output.content.length - 1;
		stream.push({ type: "toolcall_start", contentIndex, partial: output });
		const argsJson = JSON.stringify(sourceBlock.arguments || {});
		if (argsJson && argsJson !== "{}") {
			block.arguments = { ...sourceBlock.arguments };
			stream.push({
				type: "toolcall_delta",
				contentIndex,
				delta: argsJson,
				partial: output,
			});
		} else {
			block.arguments = { ...sourceBlock.arguments };
		}
		stream.push({
			type: "toolcall_end",
			contentIndex,
			toolCall: block,
			partial: output,
		});
	}

	if (source.stopReason === "error" || source.stopReason === "aborted") {
		stream.push({
			type: "error",
			reason: source.stopReason,
			error: {
				...output,
				stopReason: source.stopReason,
				errorMessage: source.errorMessage,
			},
		});
		stream.end();
		return;
	}

	stream.push({
		type: "done",
		reason: source.stopReason,
		message: {
			...output,
			stopReason: source.stopReason,
		},
	});
	stream.end();
}

function mergeAdjacentTextBlocks(blocks: AssistantBlock[]): AssistantBlock[] {
	const merged: AssistantBlock[] = [];

	for (const block of blocks) {
		const previous = merged[merged.length - 1];
		if (block.type === "text" && previous?.type === "text") {
			previous.text += block.text;
			continue;
		}
		merged.push(cloneBlock(block));
	}

	return merged;
}

function parseToolCallPayload(
	payload: string,
	runIdPrefix: string,
	index: number,
	allowedTools: Set<string>,
): ToolCall | undefined {
	const functionMatch = payload.match(/<function=([^>\s]+)>/i);
	if (!functionMatch) return undefined;

	const toolName = functionMatch[1].trim();
	if (allowedTools.size > 0 && !allowedTools.has(toolName)) return undefined;

	const args: Record<string, string> = {};
	const parameterRegex = /<parameter=([^>\s]+)>\s*([\s\S]*?)\s*<\/parameter>/gi;
	let parameterMatch: RegExpExecArray | null;

	while ((parameterMatch = parameterRegex.exec(payload)) !== null) {
		const key = parameterMatch[1].trim();
		const value = parameterMatch[2].replace(/\r/g, "").trim();
		args[key] = value;
	}

	if (Object.keys(args).length === 0) return undefined;

	return {
		type: "toolCall",
		id: `${runIdPrefix}-repair-${index}`,
		name: toolName,
		arguments: args,
	};
}

export function repairTextBlock(
	text: string,
	responseId: string | undefined,
	allowedTools: Set<string>,
): AssistantBlock[] | undefined {
	const toolRegex = /<tool_call>\s*([\s\S]*?)<\/tool_call>/gi;
	const repaired: AssistantBlock[] = [];
	let lastIndex = 0;
	let callCount = 0;
	let matched = false;
	let match: RegExpExecArray | null;

	while ((match = toolRegex.exec(text)) !== null) {
		matched = true;
		const prefix = text.slice(lastIndex, match.index);
		if (prefix) repaired.push({ type: "text", text: prefix });

		callCount += 1;
		const toolCall = parseToolCallPayload(
			match[1],
			responseId || `nemotron-${Date.now()}`,
			callCount,
			allowedTools,
		);
		if (!toolCall) return undefined;
		repaired.push(toolCall);
		lastIndex = toolRegex.lastIndex;
	}

	if (!matched) return undefined;

	const suffix = text.slice(lastIndex);
	if (suffix) repaired.push({ type: "text", text: suffix });

	return mergeAdjacentTextBlocks(repaired);
}

export function repairNemotronAssistantMessage(
	message: AssistantMessage,
	context: Context,
): AssistantMessage | undefined {
	if (message.content.some((block) => block.type === "toolCall")) return undefined;
	if (message.stopReason === "error" || message.stopReason === "aborted") return undefined;

	const allowedTools = new Set((context.tools || []).map((tool: Tool) => tool.name));
	const repairedContent: AssistantBlock[] = [];
	let repaired = false;

	for (const block of message.content) {
		if (block.type !== "text" || !block.text.includes("<tool_call>")) {
			repairedContent.push(cloneBlock(block));
			continue;
		}

		const repairedBlocks = repairTextBlock(block.text, message.responseId, allowedTools);
		if (!repairedBlocks) {
			repairedContent.push(cloneBlock(block));
			continue;
		}

		repaired = repairedBlocks.some((entry) => entry.type === "toolCall");
		repairedContent.push(...repairedBlocks);
	}

	if (!repaired) return undefined;

	return {
		...message,
		content: mergeAdjacentTextBlocks(repairedContent),
		stopReason: "toolUse",
	};
}

function applyNemotronPromptHints(context: Context, model: Model<any>): Context {
	if (!isNemotronModel(model) || !context.tools || context.tools.length === 0) return context;
	const basePrompt = context.systemPrompt || "";
	if (basePrompt.includes(NEMOTRON_TOOL_DISCIPLINE)) return context;

	return {
		...context,
		systemPrompt: basePrompt ? `${basePrompt}\n\n${NEMOTRON_TOOL_DISCIPLINE}` : NEMOTRON_TOOL_DISCIPLINE,
	};
}

function createShadowModel(model: Model<any>): Model<"openai-completions"> {
	return {
		...model,
		api: "openai-completions",
		compat: withRepairedCompat(model.compat as OpenAICompletionsCompat | undefined),
	};
}

function streamHyperstackRepaired(
	model: Model<typeof CUSTOM_API>,
	context: Context,
	options?: SimpleStreamOptions,
) {
	const shadowModel = createShadowModel(model);
	const preparedContext = applyNemotronPromptHints(context, model);
	const preparedOptions: SimpleStreamOptions = isNemotronModel(model) && preparedContext.tools?.length
		? { ...options, temperature: options?.temperature ?? 0 }
		: { ...options };

	if (!isNemotronModel(model) || !preparedContext.tools || preparedContext.tools.length === 0) {
		return streamSimpleOpenAICompletions(shadowModel, preparedContext, preparedOptions);
	}

	const stream = createAssistantMessageEventStream();

	(async () => {
		try {
			const inner = streamSimpleOpenAICompletions(shadowModel, preparedContext, preparedOptions);
			let finalMessage: AssistantMessage | undefined;

			for await (const event of inner) {
				if (event.type === "done") {
					finalMessage = event.message;
				} else if (event.type === "error") {
					finalMessage = event.error;
				}
			}

			if (!finalMessage) {
				throw new Error("Nemotron provider returned no final message.");
			}

			const repairedMessage = repairNemotronAssistantMessage(finalMessage, preparedContext) || finalMessage;
			emitAssistantMessage(stream, repairedMessage);
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			const output: AssistantMessage = {
				role: "assistant",
				content: [],
				api: model.api,
				provider: model.provider,
				model: model.id,
				usage: {
					input: 0,
					output: 0,
					cacheRead: 0,
					cacheWrite: 0,
					totalTokens: 0,
					cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
				},
				stopReason: options?.signal?.aborted ? "aborted" : "error",
				errorMessage: message,
				timestamp: Date.now(),
			};

			stream.push({ type: "start", partial: output });
			stream.push({
				type: "error",
				reason: output.stopReason,
				error: output,
			});
			stream.end();
		}
	})();

	return stream;
}

function registerHyperstackProviderOverrides(pi: ExtensionAPI): void {
	const fileConfig = loadProviderConfig();

	for (const [providerName, providerConfig] of Object.entries(fileConfig.providers)) {
		if (!TARGET_PROVIDERS.has(providerName)) continue;

		pi.registerProvider(providerName, {
			baseUrl: providerConfig.baseUrl,
			apiKey: providerConfig.apiKey,
			api: CUSTOM_API,
			compat: withRepairedCompat(providerConfig.compat),
			models: providerConfig.models.map((modelConfig) => ({
				...modelConfig,
				api: CUSTOM_API,
				compat: withRepairedCompat(modelConfig.compat || providerConfig.compat),
			})),
			streamSimple: streamHyperstackRepaired,
		});
	}
}

function shouldAppendNemotronDiscipline(ctx: ExtensionContext): boolean {
	return isNemotronModel(ctx.model) && ctx.model?.provider && TARGET_PROVIDERS.has(ctx.model.provider) && piHasTools();
}

let piHasTools = () => true;

export default function nemotronToolRepairExtension(pi: ExtensionAPI): void {
	piHasTools = () => pi.getActiveTools().length > 0;
	registerHyperstackProviderOverrides(pi);

	pi.on("before_agent_start", async (event, ctx) => {
		if (!shouldAppendNemotronDiscipline(ctx)) return;
		if (event.systemPrompt.includes(NEMOTRON_TOOL_DISCIPLINE)) return;
		return {
			systemPrompt: `${event.systemPrompt}\n\n${NEMOTRON_TOOL_DISCIPLINE}`,
		};
	});
}

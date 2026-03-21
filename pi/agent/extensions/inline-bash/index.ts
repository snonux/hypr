import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	const PATTERN = /!\{([^}]+)\}/g;
	const TIMEOUT_MS = 30000;

	pi.on("input", async (event, ctx) => {
		const text = event.text;

		// Preserve the existing whole-line !command behavior.
		if (text.trimStart().startsWith("!") && !text.trimStart().startsWith("!{")) {
			return { action: "continue" };
		}

		if (!PATTERN.test(text)) {
			return { action: "continue" };
		}

		PATTERN.lastIndex = 0;

		let result = text;
		const expansions: Array<{ command: string; output: string; error?: string }> = [];
		const matches: Array<{ full: string; command: string }> = [];
		let match = PATTERN.exec(text);

		while (match) {
			matches.push({ full: match[0], command: match[1] });
			match = PATTERN.exec(text);
		}

		for (const { full, command } of matches) {
			try {
				const bashResult = await pi.exec("bash", ["-c", command], {
					timeout: TIMEOUT_MS,
				});
				const output = bashResult.stdout || bashResult.stderr || "";
				const trimmed = output.trim();

				if (bashResult.code !== 0 && bashResult.stderr) {
					expansions.push({
						command,
						output: trimmed,
						error: `exit code ${bashResult.code}`,
					});
				} else {
					expansions.push({ command, output: trimmed });
				}

				result = result.replace(full, trimmed);
			} catch (err) {
				const errorMsg = err instanceof Error ? err.message : String(err);
				expansions.push({ command, output: "", error: errorMsg });
				result = result.replace(full, `[error: ${errorMsg}]`);
			}
		}

		if (ctx.hasUI && expansions.length > 0) {
			const summary = expansions
				.map((entry) => {
					const status = entry.error ? ` (${entry.error})` : "";
					const preview =
						entry.output.length > 50 ? `${entry.output.slice(0, 50)}...` : entry.output;
					return `!{${entry.command}}${status} -> "${preview}"`;
				})
				.join("\n");

			ctx.ui.notify(`Expanded ${expansions.length} inline command(s):\n${summary}`, "info");
		}

		return { action: "transform", text: result, images: event.images };
	});
}

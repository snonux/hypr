import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const HISTORY_FILE = join(homedir(), ".pi", "prompt-history.json");
const MAX_ENTRIES = 500;

// Load persisted history from disk. Returns entries newest-first.
function loadHistory(): string[] {
	try {
		const raw = readFileSync(HISTORY_FILE, "utf8");
		const parsed = JSON.parse(raw);
		return Array.isArray(parsed) ? parsed : [];
	} catch {
		return [];
	}
}

// Persist history to disk, capping at MAX_ENTRIES.
function saveHistory(entries: string[]): void {
	try {
		mkdirSync(join(homedir(), ".pi"), { recursive: true });
		const capped = entries.slice(0, MAX_ENTRIES);
		writeFileSync(HISTORY_FILE, JSON.stringify(capped, null, 2), "utf8");
	} catch {
		// Best-effort: don't crash the agent on a write failure.
	}
}

export default function promptHistoryExtension(pi: ExtensionAPI): void {
	// Capture every submitted prompt and append it to the persistent history file.
	pi.on("before_agent_start", async (event, _ctx) => {
		const text = event.prompt.trim();
		if (!text) return;

		const current = loadHistory();
		// Avoid duplicating the most recent entry.
		if (current[0] === text) return;

		saveHistory([text, ...current]);
	});
}
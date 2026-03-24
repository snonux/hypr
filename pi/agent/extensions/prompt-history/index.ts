import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const HISTORY_FILE = join(homedir(), ".pi", "prompt-history.json");
const MAX_ENTRIES = 500;

// Load persisted history from disk. Returns entries newest-first (same order as editor.history).
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

// Merge two newest-first lists, deduplicating consecutive identical entries,
// keeping at most MAX_ENTRIES total.
function mergeHistory(fresh: string[], persisted: string[]): string[] {
	const merged: string[] = [];
	const seen = new Set<string>();
	for (const entry of [...fresh, ...persisted]) {
		if (!seen.has(entry)) {
			seen.add(entry);
			merged.push(entry);
		}
		if (merged.length >= MAX_ENTRIES) break;
	}
	return merged;
}

export default function promptHistoryExtension(pi: ExtensionAPI): void {
	// Restore persisted history into the editor on every session start (including
	// after /reload-runtime). Entries are merged with whatever the editor already
	// has so in-session history is never lost.
	pi.on("session_start", async (_event, ctx) => {
		if (!ctx.hasUI) return;
		const persisted = loadHistory();
		if (persisted.length === 0) return;

		// getHistory returns the editor's current in-memory history (newest-first).
		const current = ctx.ui.getHistory();
		const merged = mergeHistory(current, persisted);

		// Re-seed the editor: add entries oldest-first so the final array order
		// (newest-first inside the editor) matches the merged list.
		for (const entry of [...merged].reverse()) {
			ctx.ui.addToHistory(entry);
		}

		// Persist the merged result so nothing accumulated in previous runs is lost.
		saveHistory(merged);
	});

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

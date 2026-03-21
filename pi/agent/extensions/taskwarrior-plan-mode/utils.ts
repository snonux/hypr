export interface PlanItem {
	step: number;
	text: string;
	uuid?: string;
}

export interface TaskwarriorAnnotation {
	entry?: string;
	description: string;
}

export interface TaskwarriorTask {
	id?: number;
	uuid: string;
	description: string;
	status?: string;
	priority?: string;
	start?: string;
	project?: string;
	urgency?: number;
	depends?: string[];
	annotations?: TaskwarriorAnnotation[];
}

const ANSI_PATTERN =
	// biome-ignore lint/suspicious/noControlCharactersInRegex: strips terminal escape sequences from command output
	/\u001B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])/g;

const DESTRUCTIVE_PATTERNS = [
	/\brm\b/i,
	/\brmdir\b/i,
	/\bmv\b/i,
	/\bcp\b/i,
	/\bmkdir\b/i,
	/\btouch\b/i,
	/\bchmod\b/i,
	/\bchown\b/i,
	/\bchgrp\b/i,
	/\bln\b/i,
	/\btee\b/i,
	/\btruncate\b/i,
	/\bdd\b/i,
	/\bshred\b/i,
	/(^|[^<])>(?!>)/,
	/>>/,
	/\bnpm\s+(install|uninstall|update|ci|link|publish)/i,
	/\byarn\s+(add|remove|install|publish)/i,
	/\bpnpm\s+(add|remove|install|publish)/i,
	/\bpip\s+(install|uninstall)/i,
	/\bapt(-get)?\s+(install|remove|purge|update|upgrade)/i,
	/\bbrew\s+(install|uninstall|upgrade)/i,
	/\bgit\s+(add|commit|push|pull|merge|rebase|reset|checkout|branch\s+-[dD]|stash|cherry-pick|revert|tag|init|clone)/i,
	/\bsudo\b/i,
	/\bsu\b/i,
	/\bkill\b/i,
	/\bpkill\b/i,
	/\bkillall\b/i,
	/\breboot\b/i,
	/\bshutdown\b/i,
	/\bsystemctl\s+(start|stop|restart|enable|disable)/i,
	/\bservice\s+\S+\s+(start|stop|restart)/i,
	/\b(vim?|nano|emacs|code|subl)\b/i,
];

const SAFE_PATTERNS = [
	/^\s*cat\b/,
	/^\s*head\b/,
	/^\s*tail\b/,
	/^\s*less\b/,
	/^\s*more\b/,
	/^\s*grep\b/,
	/^\s*find\b/,
	/^\s*ls\b/,
	/^\s*pwd\b/,
	/^\s*echo\b/,
	/^\s*printf\b/,
	/^\s*wc\b/,
	/^\s*sort\b/,
	/^\s*uniq\b/,
	/^\s*diff\b/,
	/^\s*file\b/,
	/^\s*stat\b/,
	/^\s*du\b/,
	/^\s*df\b/,
	/^\s*tree\b/,
	/^\s*which\b/,
	/^\s*whereis\b/,
	/^\s*type\b/,
	/^\s*env\b/,
	/^\s*printenv\b/,
	/^\s*uname\b/,
	/^\s*whoami\b/,
	/^\s*id\b/,
	/^\s*date\b/,
	/^\s*cal\b/,
	/^\s*uptime\b/,
	/^\s*ps\b/,
	/^\s*top\b/,
	/^\s*htop\b/,
	/^\s*free\b/,
	/^\s*git\s+(status|log|diff|show|branch|remote|config\s+--get)/i,
	/^\s*git\s+ls-/i,
	/^\s*npm\s+(list|ls|view|info|search|outdated|audit)/i,
	/^\s*yarn\s+(list|info|why|audit)/i,
	/^\s*node\s+--version/i,
	/^\s*python\s+--version/i,
	/^\s*curl\s/i,
	/^\s*wget\s+-O\s*-/i,
	/^\s*jq\b/,
	/^\s*sed\s+-n/i,
	/^\s*awk\b/,
	/^\s*rg\b/,
	/^\s*fd\b/,
	/^\s*bat\b/,
	/^\s*exa\b/,
];

const MUTATING_TASK_PATTERNS = [
	/\badd\b/i,
	/\bannotate\b/i,
	/\bappend\b/i,
	/\bdelete\b/i,
	/\bdenotate\b/i,
	/\bdone\b/i,
	/\bduplicate\b/i,
	/\bedit\b/i,
	/\bimport\b/i,
	/\blog\b/i,
	/\bmodify\b/i,
	/\bprepend\b/i,
	/\bpurge\b/i,
	/\bstart\b/i,
	/\bstop\b/i,
	/\bsynchronize\b/i,
	/\bundo\b/i,
];

export function stripAnsi(text: string): string {
	return text.replace(ANSI_PATTERN, "");
}

export function containsRawTaskCommand(command: string): boolean {
	return /(^|[;&|]\s*)task\b/.test(command);
}

export function isSafeAskCommand(command: string): boolean {
	const trimmed = command.trim();
	if (!trimmed.startsWith("ask ")) return false;
	if (containsRawTaskCommand(trimmed)) return false;
	if (/[;&]/.test(trimmed) || /(^|[^|])\|([^|]|$)/.test(trimmed)) return false;
	return !MUTATING_TASK_PATTERNS.some((pattern) => pattern.test(trimmed));
}

export function isSafePlanCommand(command: string): boolean {
	if (containsRawTaskCommand(command)) return false;
	if (isSafeAskCommand(command)) return true;

	const isDestructive = DESTRUCTIVE_PATTERNS.some((pattern) => pattern.test(command));
	const isSafe = SAFE_PATTERNS.some((pattern) => pattern.test(command));
	return !isDestructive && isSafe;
}

export function cleanPlanStep(text: string): string {
	return text
		.replace(/\*{1,2}([^*]+)\*{1,2}/g, "$1")
		.replace(/`([^`]+)`/g, "$1")
		.replace(/\[[^\]]+\]\([^)]+\)/g, "$1")
		.replace(/\s+/g, " ")
		.trim()
		.replace(/[.;:]+$/, "");
}

export function normalizeTaskText(text: string): string {
	return cleanPlanStep(text).toLowerCase();
}

export function extractPlanItems(message: string): PlanItem[] {
	const items: PlanItem[] = [];
	const headerMatch = message.match(/\*{0,2}Plan:\*{0,2}\s*\n/i);
	if (!headerMatch) return items;

	const planSection = message.slice(message.indexOf(headerMatch[0]) + headerMatch[0].length);
	const numberedPattern = /^\s*(\d+)[.)]\s+(.+)$/gm;

	for (const match of planSection.matchAll(numberedPattern)) {
		const cleaned = cleanPlanStep(match[2] ?? "");
		if (cleaned.length < 4) continue;
		if (cleaned.startsWith("-") || cleaned.startsWith("/")) continue;
		items.push({
			step: items.length + 1,
			text: cleaned.slice(0, 240),
		});
	}

	return dedupePlanItems(items);
}

export function dedupePlanItems(items: PlanItem[]): PlanItem[] {
	const seen = new Set<string>();
	const deduped: PlanItem[] = [];

	for (const item of items) {
		const key = normalizeTaskText(item.text);
		if (!key || seen.has(key)) continue;
		seen.add(key);
		deduped.push({
			step: deduped.length + 1,
			text: item.text,
			uuid: item.uuid,
		});
	}

	return deduped;
}

export function parseUuidList(text: string): string[] {
	return stripAnsi(text)
		.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi)
		?.map((value) => value.toLowerCase()) ?? [];
}

export function parseCreatedTaskId(text: string): number | undefined {
	const match = stripAnsi(text).match(/Created task (\d+)/i);
	return match ? Number(match[1]) : undefined;
}

export function formatTaskLine(task: TaskwarriorTask): string {
	const bits = [
		task.priority ? `[${task.priority}]` : undefined,
		task.start ? "started" : "ready",
		task.description,
	];
	return bits.filter(Boolean).join(" ");
}

export function formatTaskDetails(task: TaskwarriorTask): string {
	const annotations = (task.annotations ?? [])
		.map((annotation) => `- ${annotation.description}`)
		.join("\n");

	const lines = [
		`UUID: ${task.uuid}`,
		`Description: ${task.description}`,
		task.priority ? `Priority: ${task.priority}` : undefined,
		task.status ? `Status: ${task.status}` : undefined,
		task.start ? "Active: yes" : "Active: no",
		annotations ? `Annotations:\n${annotations}` : undefined,
	];

	return lines.filter(Boolean).join("\n");
}


import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { tmuxScrollUpArgs } from "./utils.js";

// PgUp scrolls the conversation instead of the prompt editor.
//
// pi draws inline, so past messages live in the terminal scrollback. Inside
// tmux, PgUp hands the pane to tmux copy mode one page up; from there tmux
// itself handles further PgUp/PgDn, and copy mode exits on its own when PgDn
// reaches the bottom (see utils.ts). PgDn is deliberately not bound: while
// pi has the keyboard the view is already at the bottom, so the editor's
// default PgDn (scroll a long multi-line prompt) stays available.
//
// Outside tmux nothing is registered, so PgUp keeps pi's default editor
// behaviour; use the terminal's own scrollback keys (often Shift+PgUp) there.
export default function (pi: ExtensionAPI) {
	const args = tmuxScrollUpArgs(process.env);
	if (!args) return;

	pi.registerShortcut("pageUp", {
		description: "Scroll conversation up (tmux copy mode; PgDn back down)",
		handler: async (ctx) => {
			const result = await pi.exec("tmux", args, { timeout: 2000 });
			if (result.code !== 0) {
				ctx.ui.notify(`page-scroll: tmux copy-mode failed: ${result.stderr.trim()}`, "error");
			}
		},
	});
}

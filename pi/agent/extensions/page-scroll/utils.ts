// Pure helpers for the page-scroll extension, kept free of pi imports so
// they can be unit tested with plain `node --test`.

/** The subset of process.env this extension looks at. */
export type ScrollEnv = {
	TMUX?: string;
	TMUX_PANE?: string;
};

/**
 * Arguments for the tmux command that scrolls the conversation up one page,
 * or null when pi is not running inside tmux.
 *
 * pi renders inline (no alternate screen), so the conversation history lives
 * in the terminal's scrollback, which pi itself cannot scroll. Inside tmux
 * that scrollback is reached through copy mode:
 *   -u  enter copy mode and immediately scroll up one page;
 *   -e  leave copy mode automatically once scrolled back to the bottom, so
 *       PgDn (handled by tmux's copy-mode key table while in copy mode)
 *       returns to pi's live view without pressing q.
 * TMUX_PANE pins the command to pi's own pane, not whichever pane is active.
 */
export function tmuxScrollUpArgs(env: ScrollEnv): string[] | null {
	if (!env.TMUX) return null;
	const args = ["copy-mode", "-e", "-u"];
	if (env.TMUX_PANE) args.push("-t", env.TMUX_PANE);
	return args;
}

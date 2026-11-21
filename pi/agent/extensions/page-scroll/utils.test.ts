// Run with: node --test pi/agent/extensions/page-scroll/utils.test.ts
// (Node 22.18+ strips TypeScript types natively.)
import { test } from "node:test";
import assert from "node:assert/strict";
import { tmuxScrollUpArgs } from "./utils.ts";

test("inside tmux, PgUp enters copy mode one page up on our own pane", () => {
	assert.deepEqual(tmuxScrollUpArgs({ TMUX: "/tmp/tmux-1001/default,1,0", TMUX_PANE: "%7" }), [
		"copy-mode",
		"-e",
		"-u",
		"-t",
		"%7",
	]);
});

test("inside tmux without TMUX_PANE, the current pane is targeted implicitly", () => {
	assert.deepEqual(tmuxScrollUpArgs({ TMUX: "/tmp/tmux-1001/default,1,0" }), ["copy-mode", "-e", "-u"]);
});

test("outside tmux there is nothing to drive, so no command", () => {
	assert.equal(tmuxScrollUpArgs({}), null);
	assert.equal(tmuxScrollUpArgs({ TMUX: "" , TMUX_PANE: "%1" }), null);
});

# Page Scroll

Makes `PgUp` and `PgDn` scroll the conversation in the Pi TUI when Pi runs
inside tmux.

## Why

Pi renders inline rather than on the alternate screen, so earlier messages
sit in the terminal scrollback. Pi's own `PgUp`/`PgDn` bindings
(`tui.editor.pageUp`/`pageDown`) only scroll the prompt editor, and Pi cannot
scroll the terminal scrollback itself.

## What It Does

- `PgUp` runs `tmux copy-mode -e -u -t $TMUX_PANE`: the pane enters copy mode
  one page up.
- Further `PgUp`/`PgDn` are handled by tmux copy mode (`page-up`/`page-down`).
- When `PgDn` reaches the bottom, copy mode exits by itself (`-e`) and keys go
  to Pi again. `q` or `Esc` also leave copy mode at any time.
- `PgDn` is not rebound in Pi: at the live view there is nothing below, so it
  keeps scrolling long multi-line prompts as before.
- Pickers and selectors (model selector, `/resume`, `/tree`) keep their own
  `PgUp`/`PgDn` list paging; the shortcut only fires in the prompt editor.

## Limits

- Outside tmux the extension registers nothing; use the terminal's own
  scrollback keys (often `Shift+PgUp`/`Shift+PgDn`).
- Inside tmux, `PgUp` no longer pages through a long multi-line prompt.
- Pi lists a startup notice under `[Extension issues]` saying the `pageUp`
  shortcut overrides the built-in `tui.select.pageUp`. It is harmless: the
  extension shortcut only fires in the prompt editor, so list paging in
  pickers still works. Pi has no way to silence that notice.

## Tests

```sh
node --test pi/agent/extensions/page-scroll/utils.test.ts
```

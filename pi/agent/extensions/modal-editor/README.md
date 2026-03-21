# Modal Editor

Modal prompt editing for the Pi TUI.

This is now a custom Helix-leaning modal editor for your dotfiles-backed Pi
tree. It replaces the earlier upstream toy example with a more capable normal
mode and a few prompt-editing operations that are actually useful in daily use.

## What It Does

- starts in `NORMAL` mode
- `Esc` leaves `INSERT` mode and returns to `NORMAL`
- `h`, `j`, `k`, `l` move in `NORMAL`
- `b`, `w`, `e` handle word motions in `NORMAL`
- `gh` goes to line start and `gl` goes to line end
- `gg` goes to the start of the prompt and `ge` goes to the end
- `i`, `a`, `I`, `A`, `o`, `O` enter insert mode in useful places
- `x` deletes the current character
- `D` deletes from the cursor to line end
- `dd`, `dw`, `de`, `db`, `d0`, and `d$` handle common deletes
- `u` undoes the last change

## Usage Flows

### Flow 1: Edit a prompt normally

1. Start Pi in a real terminal session.
2. You begin in `NORMAL`.
3. Move with `h`, `j`, `k`, `l`.
4. Jump by word with `b`, `w`, `e`.
5. Press `i` to start inserting text.

### Flow 2: Append instead of inserting

1. Press `a` to append after the cursor.
2. Press `A` to append at line end.
3. Press `I` to insert at line start.

### Flow 3: Use Helix-style line motions

Move to line start:

```text
gh
```

Move to line end:

```text
gl
```

You still also have `0` and `$` if you want the Vim-style single-key versions.

### Flow 4: Delete text without dropping into insert mode

Delete a character:

```text
x
```

Delete the current line:

```text
dd
```

Delete to the next word boundary:

```text
dw
```

Delete to word end:

```text
de
```

Delete from the cursor to the end of the current line:

```text
D
```

### Flow 5: Abort agent work from normal mode

When Pi is already running an agent action, `Esc` in `NORMAL` passes through to
the app-level handling, so the usual abort behavior still works.

## Notes And Limits

- This only affects interactive Pi TUI sessions.
- It does not matter in one-shot `pi -p` mode.
- This is still constrained by Pi's underlying editor model. It is a
  Helix-leaning prompt editor, not a full Helix clone with multiple selections,
  text objects, or the entire command surface.

# Session Name

Friendly session naming for Pi.

This is the upstream `session-name.ts` example installed as a local extension in
your dotfiles-backed Pi tree. It lets you label a session with something more
useful than the first prompt line.

## What It Does

- adds `/session-name [name]`
- shows the current session name when called without arguments
- sets a custom session name when called with text

## Usage Flows

### Flow 1: Name the current session

```text
/session-name hyperstack vm bootstrap review
```

### Flow 2: Check the current name

```text
/session-name
```

### Flow 3: Keep many active sessions readable

Use this when you are juggling separate Pi sessions for:

- implementation
- review
- planning
- VM1 versus VM2 work

## Notes

- This is most useful in interactive sessions where you use the session picker.
- It changes the visible session label, not the underlying worktree or model.

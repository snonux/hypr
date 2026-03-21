# Ask Mode

Exploration-only mode for Pi.

This extension adds a session-scoped `/ask` mode that turns Pi into a read-only
investigation assistant. It is meant for understanding a codebase, debugging,
reading logs, or answering questions without making changes.

## What It Does

- `/ask` enters ask mode
- `/ask <prompt>` enters ask mode and immediately sends the prompt
- `/ask-exit` leaves ask mode
- `/ask-status` shows whether ask mode is active
- limits tools to `read`, `bash`, `grep`, `find`, and `ls`
- blocks unsafe bash commands even though `bash` stays enabled
- injects per-turn instructions telling the model to inspect and explain, not implement

## Usage Flows

### Flow 1: Enter ask mode first, then explore

```text
/ask
```

Then ask questions naturally:

```text
Why does VM2 fail to reach readiness on the first create attempt?
```

### Flow 2: Enter ask mode and ask immediately

```text
/ask Compare the fresh-subagent extension behavior with what the README claims.
```

### Flow 3: Leave ask mode

```text
/ask-exit
```

That restores the previously active tool set.

### Flow 4: Check whether you are still in ask mode

```text
/ask-status
```

## Safety Model

Ask mode is meant for exploration only.

- `edit` and `write` are removed from the active tool set
- custom tools outside the ask-mode allowlist are blocked
- `bash` remains available, but only for safe read-only commands

Examples of the kind of bash commands ask mode allows:

- `rg foo src`
- `git diff`
- `ls -la`
- `sed -n '1,120p' file`
- `curl http://host/...`

Examples it blocks:

- `rm`
- `touch`
- `mkdir`
- `git commit`
- `npm install`
- `sudo ...`
- shell redirection that writes files

## Notes And Limits

- This is session-scoped and restores on resume if the session was left in ask mode.
- It is intended for investigation, not planning or implementation.
- If you ask for a change while ask mode is active, Pi should explain what would
  need to change instead of making the change.

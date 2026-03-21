# BTW

Ephemeral side questions for Pi.

This extension adds `/btw`, modeled after Claude Code's side-question flow:

- it uses the current branch conversation as context
- it asks a separate one-shot question with the current model
- it does not add the side question or answer to session history
- it does not expose tools to that side question

## Command

- `/btw <question>`
  Ask a quick side question without changing the main thread history.

## Usage Flow

### Flow 1: Ask a quick side question

```text
/btw Why did the current taskwarrior loop happen?
```

Pi will answer in a temporary overlay. Close it with `Esc`, `Enter`, or `Space`.

### Flow 2: Use it while you are in the middle of another task

```text
/btw Remind me which file currently owns the SSH host key bootstrap logic.
```

This is meant for detours and clarifications. The main conversation stays clean.

### Flow 3: Use it in non-interactive mode

```bash
pi --model openai/gpt-4.1 --no-session -p '/btw Reply with exactly BTW_OK'
```

In non-interactive mode, the answer is printed directly to stdout.

## Notes And Limits

- `/btw` uses the currently selected model.
- The side question gets current branch context, not a fresh context.
- It has no tools. If the answer is not derivable from the supplied context, it should say so.
- It is best for short clarifications, not long implementation work.

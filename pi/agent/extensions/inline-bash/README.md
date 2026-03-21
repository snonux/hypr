# Inline Bash

Inline shell expansion for Pi prompts.

This is the upstream `inline-bash.ts` example installed as a local extension in
your dotfiles-backed Pi tree. It expands `!{...}` before the prompt is sent to
the model.

## What It Does

- `!{command}` runs a shell command locally
- the command output replaces the inline expression in your prompt
- regular whole-line `!command` behavior stays unchanged

## Usage Flows

### Flow 1: Inline one value into a prompt

```text
What files are in !{pwd}?
```

Pi sends the expanded prompt after `pwd` runs locally.

### Flow 2: Inline git state

```text
Summarize the current branch !{git branch --show-current} and these changes: !{git status --short}
```

### Flow 3: Inline system context

```text
I am on kernel !{uname -r} and hostname !{hostname}. Explain whether that matters for this bug.
```

## Notes And Limits

- Commands run on your local machine, not on the model provider.
- Expansion happens before the prompt is sent.
- Each inline command has a 30 second timeout.
- If a command fails, the prompt gets an inline error marker.
- This is convenient, but it is still shell execution. Treat prompt text
  accordingly.

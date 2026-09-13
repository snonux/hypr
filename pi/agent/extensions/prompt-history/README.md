# Prompt History

Persistent prompt logging for Pi.

This is a local extension (not an upstream pi example). It captures every
prompt you submit and appends it to a persistent history file, so there is a
record of what you have asked across sessions.

## What It Does

- hooks `before_agent_start` and records the prompt text
- writes to `~/.pi/prompt-history.json`, newest first
- caps the file at the last 500 entries
- skips a prompt identical to the most recent entry
- best-effort only: a write failure never crashes the agent

## Usage

There are no commands. Read the file when you want it back:

```bash
head ~/.pi/prompt-history.json
```

## Notes

- It records submitted prompts, not the full conversation.
- There is no recall UI yet; the JSON file is the interface.
- The file lives in your dotfiles-backed `~/.pi` tree, so it survives
  extension reloads and is yours to back up or delete.

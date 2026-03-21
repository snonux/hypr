# Handoff

Focused session handoff for Pi.

This is the upstream `handoff.ts` example installed as a local extension in
your dotfiles-backed Pi tree. It generates a compact, self-contained prompt for
starting a new session without manually rewriting the whole context.

## What It Does

- adds `/handoff <goal>`
- reads the current session branch
- asks the active model to summarize the relevant context for a new thread
- opens the generated handoff prompt for editing
- creates a new session and drops the edited prompt into the new editor

## Usage Flows

### Flow 1: Split off the next implementation phase

```text
/handoff implement the next phase of the WireGuard cleanup work
```

Pi generates a fresh prompt with the relevant context, opens it for editing,
creates a new session, and leaves the draft ready to submit.

### Flow 2: Move into a review-only thread

```text
/handoff independently review the recent hyperstack changes for concrete bugs and missing tests
```

### Flow 3: Continue with a narrower subproblem

```text
/handoff investigate only the SSH host verification path and ignore the rest
```

## Notes And Limits

- This is for interactive Pi sessions with UI support.
- It uses the currently selected model to generate the handoff prompt.
- It is a session-to-session context transfer helper, not the same thing as the
  fresh subagent extension.

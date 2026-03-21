# Fresh Subagent

Generic fresh-context delegation for Pi with live status, per-run log files, and
history browsing.

This extension gives Pi a simple subagent primitive:

- the main agent can call the `subagent` tool
- you can call `/subagent <prompt>` directly
- delegated work runs in a new `pi --mode json -p --no-session` process
- the child starts with a fresh context
- each run gets its own log file plus JSON sidecar metadata
- you can list past runs and open any run's full transcript in `$VISUAL` or `$EDITOR`

This is still intentionally small. It does not manage agent pools, agent
catalogs, or planner chains. It is meant for focused delegation with a clean
context and auditable output.

## What It Is For

Subagents are generic. The main agent can hand them any focused prompt that
benefits from a clean context, for example:

- code review
- debugging
- focused research
- second-opinion architecture checks
- summarizing noisy output
- validating whether a task is really complete
- any other self-contained side task

One common use is the `taskwarrior-task-management` review loop:

1. The main agent implements the change
2. The main agent self-reviews the change
3. The main agent uses `subagent` for an independent fresh-context review
4. The main agent fixes findings
5. Only then does the task move toward completion

## Usage Flow

### Step 1: Run a subagent

Direct delegation:

```text
/subagent Compare the current plan-mode extension behavior against the requested workflow and list only the mismatches.
```

Focused investigation:

```text
/subagent Find all code paths that write to the SSH known_hosts file and summarize the risk.
```

Independent review:

```text
/subagent Independently review the recent changes for bugs, regressions, and missing tests. Only report concrete findings.
```

The watched slash command is the normal interactive path. It updates status in
the footer, keeps a widget with recent activity, and writes the full run to a
durable log file.

### Step 2: Inspect history

List recent runs:

```text
/subagent-history
```

List more:

```text
/subagent-history 20
```

Each entry includes:

- run ID
- status
- started timestamp
- prompt summary
- log path
- output preview when available

You can select later runs either by:

- `latest`
- numeric index from `/subagent-history`
- run ID prefix

### Step 3: Inspect a specific run

Show the paths and metadata for the latest run:

```text
/subagent-log
```

Show the paths and metadata for a specific run:

```text
/subagent-log 3
/subagent-log 20260320T194522-review-ssh
```

This prints:

- run ID
- status
- prompt
- log path
- metadata path
- `tail -f` command

### Step 4: Open the full transcript in Helix or another editor

Open the latest run in `$VISUAL` or `$EDITOR`:

```text
/subagent-open
```

Open a specific run:

```text
/subagent-open 2
/subagent-open 20260320T194522-review-ssh
```

In TUI mode the extension temporarily releases the terminal, launches your
configured editor, then restores Pi when you exit the editor.

In one-shot or print mode it runs the editor command directly.

## Other Commands

Alias with the same watched behavior:

```text
/subagent-watch <prompt>
```

Launch a visible fresh Pi session instead of a headless child:

```text
/subagent-session <prompt>
```

This is useful when you want to watch the subagent itself, not just the logged
transcript.

## Tool Usage From The Main Agent

Because this extension registers a `subagent` tool, the main agent can call it
itself.

Generic handoff pattern:

```text
Use the subagent tool for a fresh-context pass on this side task, then return only the useful result.
```

Review handoff pattern:

```text
First review your own changes. Afterwards, use the subagent tool to perform an independent fresh-context review and then address any findings.
```

Research handoff pattern:

```text
Use the subagent tool to inspect only the WireGuard setup path in a fresh context and summarize the concrete risks.
```

## One-Shot CLI Mode

This works outside the full TUI as well:

```bash
pi --model openai/gpt-4.1 --no-session -p '/subagent Say only SUBAGENT_COMMAND_OK'
pi --no-session -p '/subagent-history'
pi --no-session -p '/subagent-log latest'
```

If you want to open a run from a shell:

```bash
pi --no-session -p '/subagent-open latest'
```

## What To Put In The Prompt

Subagents start fresh, so include enough context in the prompt:

- what to inspect or do
- the scope or files to focus on
- the expected output shape
- any constraints such as “report only concrete findings”

Good:

```text
/subagent Review the recent SSH bootstrap changes in hyperstack.rb. Report only concrete bugs, regressions, or missing tests.
```

Weak:

```text
/subagent Review this
```

## Log Storage

Fresh-subagent history lives under:

```text
${XDG_STATE_HOME:-~/.local/state}/pi/subagents
```

Each run creates:

- one `*.log` transcript file
- one `*.json` metadata file
- a rolling `latest.log` symlink pointing at the newest run

That means you can also inspect logs outside Pi with tools like:

```bash
tail -f ~/.local/state/pi/subagents/latest.log
ls ~/.local/state/pi/subagents
```

## Notes And Limits

- The headless subagent uses a fresh session via `--no-session`.
- The subprocess still runs in the same working directory unless you override
  `cwd`.
- The extension disables itself inside child subagent processes to avoid
  accidental recursive registration.
- `subagent-session` is visible because it uses a real Pi session instead of a
  headless child. Its transcript is the session itself, not one of the
  `fresh-subagent` log files.

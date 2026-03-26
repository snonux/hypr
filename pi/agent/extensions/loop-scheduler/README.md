# Loop Scheduler

Session-scoped recurring and reactive prompts for Pi.

This extension adds two commands for interactive Pi sessions:

- `/loop` re-sends a prompt on an interval while the current Pi process stays open.
- `/watch` posts a predefined prompt when the agent becomes idle or when an assistant response contains a substring.

## Commands

### `/loop`

- `/loop 10m <prompt>`
  Run a prompt every 10 minutes.
- `/loop <prompt>`
  Run a prompt every 10 minutes using the default interval.
- `/loop <prompt> every 2h`
  Alternative trailing interval form.
- `/loop list`
  Show the active loop jobs.
- `/loop cancel <id>`
  Cancel one loop job.
- `/loop cancel all`
  Cancel all loop jobs.

### `/watch`

- `/watch <prompt>`
  Run a prompt whenever the agent becomes idle.
- `/watch idle => <prompt>`
  Explicit idle watch form.
- `/watch contains <needle> => <prompt>`
  Post the prompt when an assistant response includes `<needle>`.
- `/watch list`
  Show the active watch jobs.
- `/watch cancel <id>`
  Cancel one watch job.
- `/watch cancel all`
  Cancel all watch jobs.

Supported units:

- `s`
- `m`
- `h`
- `d`

Examples:

- `5s`
- `10m`
- `2h`
- `1d`
- `every 2 hours`
- `hourly`
- `daily`

## Usage Flows

### Flow 1: Poll something on an interval

Start Pi in the repo, then run:

```text
/loop 10m check whether the deployment finished and summarize what changed
```

Pi will keep re-injecting that prompt every 10 minutes while the session stays
open.

### Flow 2: Loop another command

The scheduled prompt can itself be a slash command or workflow:

```text
/loop 20m /work-on-tasks highest-impact 1
```

or:

```text
/loop 30m /subagent Review the current working tree for concrete regressions only
```

### Flow 3: Check what is scheduled

```text
/loop list
```

This prints the current loop IDs, cadence, next due time, and prompt preview.

### Flow 4: Cancel a loop

Cancel one loop:

```text
/loop cancel ab12cd34
```

Cancel everything:

```text
/loop cancel all
```

### Flow 5: Trigger a prompt when the agent goes idle

```text
/watch idle => summarize what you just finished and suggest the next step
```

This prompt fires whenever the agent transitions from busy to idle.

### Flow 6: Trigger a prompt when a response contains text

```text
/watch contains error => inspect the error and report the concrete failure
```

The substring match is case-sensitive and is checked against assistant responses.

### Flow 7: Work from watch presets

Watch presets live in:

```text
~/.pi/agent/extensions/loop-scheduler/watch-presets.md
```

Preset lines use:

```text
* name: idle => prompt text
* name: contains needle => prompt text
```

## Busy-Agent Behavior

Loop jobs do not spam turns while Pi is busy.

- if a job becomes due while the agent is running, it is marked pending
- when the current work finishes, the next pending loop fires once
- missed intervals do not stack into a catch-up storm

Watch jobs behave similarly:

- idle watches queue when the agent becomes idle
- substring watches queue when an assistant response matches the needle
- only one queued prompt is sent at a time, so watches do not overlap

## Session Model

This extension is session-scoped, not durable scheduling.

- loop jobs live only in the current Pi process
- watch jobs live only in the current Pi process
- closing Pi ends all loop jobs
- `/reload` or a restart drops the active schedules
- this is for active coding sessions, not unattended automation

## Good Uses

- poll build or deployment status
- re-run a review command every N minutes
- check Taskwarrior progress during a work session
- periodically ask for a summary while you are coding

## Bad Uses

- long-term unattended automation
- guaranteed exact-time scheduling
- anything that must survive terminal exit or Pi restart

## Notes

- `/loop` is intended for interactive or RPC sessions that remain open.
- It is not useful in one-shot `pi -p` mode because the process exits before
  later runs can fire.

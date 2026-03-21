# Taskwarrior Plan Mode

Taskwarrior-backed planning for Pi.

This extension keeps planning and execution separate:

- use `/plan` to enter read-only planning mode
- ask Pi to produce a numbered `Plan:`
- convert the extracted plan into Taskwarrior tasks explicitly
- leave planning mode and continue execution against real tasks

Taskwarrior remains the source of truth. This extension does not keep a private
todo list.

## Commands

- `/plan`
  Enter read-only planning mode. The active tool set is reduced to safe
  exploration tools.
- `/plan-exit`
  Leave planning mode and restore the previous tool set.
- `/plan-create-tasks [sequential|independent]`
  Create Taskwarrior tasks from the last extracted `Plan:`.
- `/task-sync [sequential|independent]`
  Legacy alias for `/plan-create-tasks`.
- `/task-update <selector> :: <new description>`
  Replace a task description.
- `/task-modify <selector> :: <mods>`
  Apply raw `ask ... modify ...` arguments to a task.
- `/tasks`
  Show started and `+READY` tasks for the current repo.
- `/task-next [run]`
  Focus the started task, or start the next `+READY` task.
- `/task-exit`
  Leave Taskwarrior focus mode.
- `/task-unfocus`
  Alias for `/task-exit`.
- `/work-on-tasks [strategy] [max]`
  Kick off the Taskwarrior execution loop aligned to the
  `taskwarrior-task-management` workflow.

## Rules

- all Taskwarrior operations go through `ask`, never raw `task`
- tasks are scoped to the current git repo through your `ask` wrapper
- use UUIDs for stable references
- planning mode is read-only by design
- the extracted plan is session-local, so `/plan`, the planning prompt,
  `/plan-create-tasks`, and `/plan-exit` should happen in the same interactive
  or continued Pi session

## Usage Flows

### Flow 1: Turn a plan into Taskwarrior tasks

1. Start Pi in the project.
2. Run:

```text
/plan
```

3. Ask for analysis and a numbered `Plan:`. Example:

```text
Analyze the current repo and propose a concise Plan: for fixing the SSH bootstrap trust model.
```

4. After Pi replies with a `Plan:`, create tasks:

```text
/plan-create-tasks sequential
```

5. Leave planning mode:

```text
/plan-exit
```

Use `sequential` when each step should depend on the previous one. Use
`independent` when the planned tasks can be worked separately.

### Flow 2: Adjust a task after planning

Rewrite a task description:

```text
/task-update uuid:12345678-1234-1234-1234-123456789abc :: Restore SSH host verification during bootstrap
```

Apply standard modify arguments:

```text
/task-modify uuid:12345678-1234-1234-1234-123456789abc :: priority:H +security
```

Use Taskwarrior replacement syntax:

```text
/task-modify uuid:12345678-1234-1234-1234-123456789abc :: /bootstrap/provisioning/
```

### Flow 3: Start executing the real tasks

See what is active:

```text
/tasks
```

Focus the current task:

```text
/task-next
```

Focus and immediately start execution:

```text
/task-next run
```

Leave focus mode again:

```text
/task-exit
```

Run the full repo task loop:

```text
/work-on-tasks highest-impact
```

### Flow 4: Planning session pattern

This is the cleanest end-to-end interactive pattern:

```text
/plan
```

```text
Analyze the repo and give me a Plan: for the next implementation slice.
```

```text
/plan-create-tasks sequential
```

```text
/plan-exit
```

```text
/work-on-tasks
```

## Notes And Limits

- Planning mode is read-only by design.
- All Taskwarrior operations still go through `ask`, never raw `task`.
- `ask` must use real Taskwarrior CLI syntax. It is not a natural-language
  task assistant and should never be called like `ask taskwarrior-task-management ...`.
- Execution mode injects the current Taskwarrior task back into the agent prompt
  so the model works against the real task rather than an in-memory checklist.
- Execution mode now treats the focused task as the already-selected starting
  point and blocks repeated identical `ask uuid:<current>` lookups until the
  agent has moved on to repo inspection, implementation, tests, review, or a
  different command.
- Full `/plan` state is not meant to be passed across unrelated one-shot `pi -p`
  invocations. Use a real interactive or continued session for planning.

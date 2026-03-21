# Reload Runtime

Runtime reload support for Pi.

This is the upstream `reload-runtime.ts` example installed as a local extension
in your dotfiles-backed Pi tree. Pi does not ship a `reload-runtime.sh`
extension in the bundled examples; the actual upstream example is TypeScript and
registers both a slash command and a tool.

## What It Does

- adds `/reload-runtime`
- adds the `reload_runtime` tool
- reloads extensions, skills, prompts, and themes in the current Pi session

## Usage Flows

### Flow 1: Reload after editing dotfiles

1. Edit an extension, skill, prompt, or theme on disk.
2. In the same Pi session, run:

```text
/reload-runtime
```

3. Pi reloads the runtime without restarting the process.

### Flow 2: Let the agent request a reload

Because this also exposes a tool, the agent can ask to reload the runtime when
that makes sense:

```text
Use the reload_runtime tool after updating the extension files so the new command set is active.
```

The tool queues `/reload-runtime` as a follow-up command.

## Notes And Limits

- Reload affects the current Pi session only.
- It is most useful in an interactive session that stays open while you are
  editing your Pi configuration.
- In one-shot `pi -p` usage, reload is usually not very interesting because the
  process exits immediately after handling the prompt.

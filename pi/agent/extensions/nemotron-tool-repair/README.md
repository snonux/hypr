# Nemotron Tool Repair

Makes Hyperstack Nemotron sessions more reliable inside Pi when tools are
enabled.

It does two things:

- adds a Nemotron-specific tool-use hint to the system prompt so the model stops
  narrating before acting
- wraps the Hyperstack OpenAI-compatible providers and repairs raw
  `<tool_call> ... </tool_call>` text into real Pi tool calls when vLLM misses it

This keeps your existing model names and startup scripts unchanged.

## What It Affects

Only Hyperstack Nemotron models are changed:

- `hyperstack1/cyankiwi/NVIDIA-Nemotron-3-Super-120B-A12B-AWQ-4bit`
- `hyperstack2/cyankiwi/NVIDIA-Nemotron-3-Super-120B-A12B-AWQ-4bit`

Other Hyperstack models such as Qwen3 Coder still use the same endpoints and
same model IDs, but they do not go through the Nemotron repair path.

## Usage Flow

Start Pi the same way as before:

```bash
cd /home/paul/git/conf/snippets/hyperstack
./pi-vm1
```

or explicitly:

```bash
pi --model 'hyperstack1/cyankiwi/NVIDIA-Nemotron-3-Super-120B-A12B-AWQ-4bit'
```

Then use Pi normally. There are no new commands for this extension.

When Nemotron behaves well:

- Pi receives a normal structured tool call
- the extension stays out of the way

When Nemotron emits raw XML-like tool text instead:

- the extension buffers that assistant turn
- parses `<tool_call>`, `<function=...>`, and `<parameter=...>` blocks
- converts them into real Pi tool calls
- hands the repaired assistant message back to the agent loop

## What The Repair Handles

The repair path is aimed at outputs shaped like this:

```text
<tool_call>
<function=bash>
<parameter=command>
pwd
</parameter>
</function>
</tool_call>
```

It preserves surrounding text if Nemotron narrated before the tool call.

## Practical Notes

- The repair path only runs when tools are active.
- Nemotron tool turns are buffered before they are shown, so those turns may
  feel less streaming than Qwen or GPT.
- The extension also disables `strict` in OpenAI-compatible tool schemas for
  the Hyperstack providers, which removes the repeated vLLM warning about
  ignored `strict` fields.

## If You Want To Disable It

Temporarily disable the extension by moving or renaming this directory:

```text
~/.pi/agent/extensions/nemotron-tool-repair
```

Then restart Pi or use `/reload` in an existing Pi session.

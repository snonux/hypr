# Updating an Ollama cloud model in hypr

Applies to subscription models served via ollama.com (the `ollama-cloud` provider,
e.g. swapping `kimi-k2.7-code:cloud` → `kimi-k3.1-pro:cloud`). Two files hold every
reference, both consumed through symlinks — edit the repo copy only:

| File | Symlinked as | Holds |
|------|--------------|-------|
| `pi/agent/models.json` | `~/.pi/agent/models.json` | `ollama-cloud` provider model catalog |
| `hypr.fish` | `~/.config/fish/conf.d/hypr.fish` | fish abbreviations (`pik`, `kimi`, …) |

Switching the vLLM model on a Hyperstack VM is a different flow — see the
[Switching models](../README.md#switching-models) section in README.md.

## 1. Find the exact tag on the registry

Cloud tags end in `:cloud`, but the version you expect may not be the tag that
exists (`kimi-k3.1` → actually `kimi-k3.1-pro`). List what the subscription offers:

```bash
curl -s https://ollama.com/v1/models \
  -H "Authorization: Bearer $OLLAMA_API_KEY" \
  | python3 -c "import sys,json; print('\n'.join(m['id'] for m in json.load(sys.stdin)['data']))"
```

Inspect context length, capabilities (vision/thinking/tools) and parameter count:

```bash
ollama show <model>:cloud
# or: curl -s https://ollama.com/api/show -d '{"name":"<model>:cloud"}' | python3 -m json.tool
```

## 2. Test before wiring it in

Chat test plus a tool-call test — pi is a coding agent, so tool calling must work:

```bash
# Chat
curl -s https://ollama.com/v1/chat/completions \
  -H "Authorization: Bearer $OLLAMA_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"<model>:cloud",
       "messages":[{"role":"user","content":"Reply with exactly: hello"}],
       "stream":false}' | python3 -m json.tool

# Tool call — expect tool_calls + finish_reason "tool_calls" in the response
curl -s https://ollama.com/v1/chat/completions \
  -H "Authorization: Bearer $OLLAMA_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"<model>:cloud",
       "messages":[{"role":"user","content":"Weather in Berlin? Use the tool."}],
       "tools":[{"type":"function","function":{"name":"get_weather",
         "description":"Get current weather for a city",
         "parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}],
       "stream":false}' | python3 -m json.tool
```

## 3. Update `pi/agent/models.json`

Under `providers → ollama-cloud → models`, replace the old entry (or add a new one).
Take `contextWindow` from the `ollama show` context length and choose `maxTokens`
by hand (it is not reported by `show`); subscription models keep `cost` at 0:

```json
{
  "id": "kimi-k3.1-pro:cloud",
  "name": "kimi k3.1 pro 2.8T [ollama]",
  "reasoning": true,
  "input": ["text", "image"],
  "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
  "contextWindow": 1048576,
  "maxTokens": 32768
}
```

Validate afterwards: `python3 -m json.tool pi/agent/models.json >/dev/null && echo ok`.

## 4. Update `hypr.fish`

Retarget the generic aliases (`kimi`, `pik`, `pi-ollama-kimi`, …) to the new model
and rename version-tagged ones (`pi-ollama-kimi-k27-1042b` → `pi-ollama-kimi-k31-pro-28t`,
`pik7` → `pik31`), following the name-version-paramcount convention.

`abbr` lines in `hypr.fish` are re-created by every new fish shell (fish 4.0.2,
verified 2026-11-17: removed names such as `pik7` are gone in a fresh shell), so
open a new shell to pick up the change. Only if you ever defined an abbreviation
with `abbr -U` (universal) does a removed name persist; then run
`fish -c 'abbr --erase <old-name>'` once.

## 5. Verify end to end

```bash
pi --provider ollama-cloud --model <new-model>:cloud -p "What model are you?"
# then, in a fresh fish shell:
pik    # or whichever abbreviation you retargeted
```

## Caveats

- Replacing an entry in step 3 deletes the old one: if old pi sessions reference
  it, resume fails on model lookup. Add the new entry and keep the old one until
  those sessions are done if you still need them.
- Ollama cloud "thinking" models emit reasoning with every reply; pi handles it via
  `reasoning: true`, so the status bar and context stay correct.
- `ollama show <name>` without the `:cloud` suffix searches the local machine and
  reports "model not found" — that does not mean the cloud model is unavailable.

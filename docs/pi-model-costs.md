# Updating pi model costs (OpenRouter)

The cost in pi's status bar is **not** returned by OpenRouter — pi multiplies the
API-reported token counts by static per-million prices shipped in its model catalog
(`node_modules/@earendil-works/pi-ai/dist/models.generated.js`, `calculateCost()` in
`models.js`). If OpenRouter changes prices, the displayed cost drifts until fixed.

**Check installed vs latest pi:**

```bash
npm view @earendil-works/pi-coding-agent version
node -p "require('/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/package.json').version"
```

**Normal fix — update pi** (refreshes the whole generated catalog):

```bash
npm install -g @earendil-works/pi-coding-agent
```

**Verify a model's prices against OpenRouter's live table** (`pricing.prompt` /
`pricing.completion` are per token; multiply by 1e6 for pi's per-million format):

```bash
curl -s https://openrouter.ai/api/v1/models \
  | python3 -c "
import sys, json
for m in json.load(sys.stdin)['data']:
    p = m['pricing']
    print(f\"{m['id']}: input={float(p['prompt'])*1e6} output={float(p['completion'])*1e6}\")
" | grep <model-id>
```

**Override a specific model** if it's still wrong after updating pi (or the model
isn't in the catalog). Add/merge into `~/.pi/agent/models.json` — `cost` fields are
partial (only listed fields replace built-in values), values in $/million tokens:

```json
{
  "providers": {
    "openrouter": {
      "modelOverrides": {
        "<model-id>": {
          "cost": { "input": 3, "output": 15, "cacheRead": 0.3, "cacheWrite": 3.75 }
        }
      }
    }
  }
}
```

Caveats:

- OpenRouter has no single canonical price per model — routes and variants
  (`:floor`, `:nitro`) differ. The per-million rate is an estimate; only override
  models where the drift matters.
- A missing/unknown model ID in `modelOverrides` is silently ignored; an uncataloged
  model shows `$0.000` ("no known price", not free).
- Docs: `docs/models.md` ("Per-model Overrides") in the pi install directory.

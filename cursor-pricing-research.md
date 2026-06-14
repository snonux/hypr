# Cursor: Models & Pricing Research

Research compiled 2026-06-03. Sources: cursor.com/pricing,
cursor.com/docs/models-and-pricing, Morph, CloudZero, Vantage, Apidog,
eesel AI, devtoolsreview, beyondtmrw.org (Composer 2.5 release coverage).

---

## 1. What Cursor is

Cursor is an AI-native code editor (VS Code fork) made by Anysphere.
It bundles frontier models (Claude, GPT, Gemini, DeepSeek, plus its own
Cursor Composer) into agentic editing, multi-file Composer edits, Tab
autocomplete, and cloud/background agents. As of early 2026 Anysphere
reportedly crossed $2B ARR with >1M paying subscribers, used by 64% of
Fortune 500.

---

## 2. Subscription plans (cursor.com/pricing, May 2026)

| Plan        | Price            | Annual (~20% off) | Credit pool     | Notes                              |
|-------------|------------------|-------------------|-----------------|------------------------------------|
| Hobby       | Free             | —                 | None            | Limited Agent + Tab, ~1 wk Pro trial |
| Pro         | $20 / mo         | ~$16 / mo         | $20             | All frontier models, Cloud agents  |
| Pro+        | $60 / mo         | ~$48 / mo         | $60 (3× Pro)    | Heavy daily coding                 |
| Ultra       | $200 / mo        | ~$160 / mo        | $400 (20× Pro)  | Power users, priority features     |
| Teams       | $40 / user / mo  | ~$32 / user / mo  | $20 / seat      | SSO, admin, analytics              |
| Enterprise  | Custom           | Annual only       | Pooled usage    | SCIM, audit logs, SLA              |

Key shift: in June 2025 Cursor moved from "500 fast requests / month"
to a credit-based system — your subscription buys a $ pool of API
credits. After the pool is gone, overages are billed at the underlying
model's API rate (no penalty markup), or you can upgrade.

---

## 3. Models Cursor exposes

Per the docs and 2026 coverage, the model picker includes roughly:

- **OpenAI**: GPT-5.4, GPT-5.4-mini, GPT-5.5, o3-mini, GPT-4.5
- **Anthropic**: Claude 4 Sonnet, Claude 4 Opus, Claude 4.6 Opus
- **Google**: Gemini 3 Pro
- **xAI / DeepSeek / others** appear intermittently
- **Cursor Composer 2.5** — Cursor's own agentic coding model
  (built on Moonshot Kimi K2.5 with Cursor's own RL post-training),
  released 2026-05-18, default in Agent mode
- **Auto** — Cursor's router that picks a cost-efficient model for you

Exact availability shifts frequently; the docs page
(cursor.com/docs/models-and-pricing) is the live source.

---

## 4. Per-model cost (per million tokens, May 2026 list prices)

Cursor charges the underlying provider's API rate. A representative
slice (numbers from Cursor docs and third-party reports):

| Model                       | Input $/MTok | Output $/MTok | Relative cost in Cursor pool |
|-----------------------------|--------------|---------------|------------------------------|
| Cursor Composer 2.5 Standard| $0.50        | $2.50         | cheapest frontier agent      |
| Cursor Composer 2.5 Fast    | $3.00        | $15.00        | default in product, low-latency |
| Cursor Auto (router)        | $0.25 cache read / $1.25 input / $6.00 output | — | "included" on paid plans — does **not** drain the credit pool |
| GPT-5.4 (typical fast)      | $2.50        | $15.00        | 1× base                      |
| GPT-5.4-mini                | ~            | ~             | 0.5× (cheapest non-Auto)     |
| Claude 4 Sonnet             | ~$3 / $3-5   | ~$15          | ~1× base                     |
| Gemini 3 Pro                | ~$1-2        | ~$6-12        | ~1× base                     |
| o3-mini                     | ~$3          | ~$12          | ~2× (reasoning)              |
| Claude 4 Opus               | $5.00        | $25.00        | 5–10× — drains the pool fast  |
| GPT-4.5                     | ~$5-10       | ~$15-30       | 5–10×                        |

These are public-list / community-derived numbers; Cursor does not
publish a single tidy table, but Settings → Account → Usage shows your
real per-request burn.

Approximate requests per $20 Pro pool (community reports, late 2025 / 2026):

- ~500 with GPT-5.4 / GPT-5.4-mini
- ~225 with Claude 4 Sonnet
- ~45–90 with Claude 4 Opus or GPT-4.5
- **Unlimited** with Auto (no pool deduction)

Cursor does **not** charge a markup on Auto on paid plans, but adds a
"Cursor Token Rate" of $0.25 / MTok on top of API pricing for non-Auto
agent requests on Teams plans.

---

## 5. The two modes (Normal vs Max)

| | Normal mode | Max mode |
|---|---|---|
| Pricing | Fixed per-request, drawn from credit pool | Token-based: API rate + 20% margin |
| Tool calls / interaction | 25 | 200 |
| Context | Truncated to ~10–15K | Full model context (up to 200K, 1M for some) |
| Slow fallback | Yes (10/day after fast is out) | No — requires usage-based billing |

Max Mode is where the surprise bills come from: a single complex
session with 150 tool calls, 200K input, 20K output can cost $3–8;
three of those per day = $180–500 / month on top of the subscription.

---

## 6. How the price relates to Auto

This is the single most important thing to understand about Cursor's
pricing in 2026.

**Auto mode is the only "free" path on a paid plan.** When you let
Cursor pick the model, the request is included — it does not consume
your credit pool. Auto is priced by Cursor at roughly:

- $0.25 / MTok cache read
- $1.25 / MTok input
- $6.00 / MTok output

…but on a paid plan those amounts are absorbed into the subscription
(per the Vantage breakdown). You only pay from the pool when you
**manually pin** a frontier model (Claude Sonnet, GPT-4.5, Opus,
etc.) or when you switch to **Max Mode** (which is always metered).

Practical effect:

- **Auto-only workflow** → $20 Pro feels essentially "unlimited" for
  chat/agent; same as the old 500-request plan, possibly more
  generous.
- **Hand-picked Sonnet for everything** → ~225 requests / month from
  the $20 pool, then overages at API rate.
- **Hand-picked Opus / Max Mode for heavy work** → $20 pool can be
  gone in a single session; $200–500 / mo bills are reported.

So the relationship is:

> The credit pool is the *budget for explicit model choices*. Auto is
> the *included, pooled* tier. The more you let Auto pick, the closer
> Cursor behaves to flat-rate; the more you pin a frontier model or
> use Max Mode, the more it behaves like raw metered API spend with a
> small Cursor markup.

---

## 7. Hidden cost traps to watch

- **Overage billing** — past the pool you can opt into pay-as-you-go
  at API rate. $0.04 / "premium request" was the old rule; under the
  credit system it's straight token cost. Set a hard cap.
- **Max Mode** — turns off after fast requests run out; needs
  usage-based billing. Big-billed silently.
- **Tab completions** — unlimited on paid plans, but model-powered
  ones still draw from the pool.
- **Background / Cloud Agents** — metered per task, often Max-Mode
  pricing.
- **No credit roll-over** — unused pool evaporates each month.
- **Composer vs Auto** — Composer 2.5 Standard at $0.50 / $2.50 is
  dramatically cheaper per task than Opus ($5 / $25) at near-parity
  coding intelligence (79.8% vs 80.5% on SWE-Bench Multilingual), so
  pinning the cheapest agent model is often the best $/quality trade.
- **BYOK** — Bring Your Own OpenAI / Anthropic key is supported;
  bypasses the pool entirely, you pay the provider directly. Useful
  for users with negotiated enterprise API pricing.

---

## 8. Quick "what should I expect to pay" guide

| Usage pattern | Plan that fits | Realistic monthly cost |
|---|---|---|
| Hobby / evaluate | Hobby | $0 |
| Individual dev, mostly Auto + occasional Sonnet | Pro | $20 |
| Heavy agent / pinned-Sonnet | Pro+ | $60 |
| All-day Opus / Max Mode | Ultra | $200 + likely overages |
| 3-person team, mostly Auto | Teams | $120 ($40×3) |
| 25-person engineering org | Enterprise | Custom, pooled; budget ~$12K–$30K/yr |

---

## TL;DR

Cursor charges a subscription that includes (a) a dollar pool of API
credits and (b) **unlimited Auto-mode usage**. Picking a frontier model
by hand burns the pool at 1× (cheap models) to 10× (Opus / GPT-4.5) the
base rate. Max Mode is always metered at API rate + 20% and is where
unexpected bills hide. The cheapest competitive path is Auto + Cursor
Composer 2.5 Standard ($0.50 / $2.50 per MTok), which is roughly 10×
cheaper than Opus at near-parity coding benchmark scores.

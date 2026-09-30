# Speculative decoding (MTP) for Qwen3.8 27B

Qwen3.8-27B ships a built-in MTP (multi-token prediction) layer
(`mtp_num_hidden_layers: 1` in its config, weights in `mtp.safetensors`). vLLM uses
it as a cheap drafter: the MTP head guesses the next N tokens, the full model
verifies them in one forward pass, and every guess up to the first mismatch is kept.
Decode is memory-bandwidth-bound on the A100, so verifying a few extra tokens per
pass is almost free.

## Config

```toml
[vllm.presets.qwen38-27b]
speculative_config = { method = "mtp", num_speculative_tokens = 3 }
```

hypr passes this to vLLM as `--speculative-config '{"method":"mtp","num_speculative_tokens":3}'`.
On by default; `--no-speculative` on `create` / `model switch` turns it off.

## Benchmark (2026-09-30)

A100 80 GB PCIe, `Qwen/Qwen3.8-27B-FP8`, vLLM nightly (v0.30.1rc1.dev396), thinking
off, 6 Go coding prompts, 700 output tokens each, measured with
[`bench/decode_bench.py`](../bench/decode_bench.py). Per-request decode tok/s is the
median; aggregate is total tokens / wall time.

| Setup | 1 conversation (greedy) | 1 conversation (T=0.7) | 3 conversations total (greedy) | 3 conversations total (T=0.7) | Mean acceptance length | KV cache |
|---|---|---|---|---|---|---|
| no speculative | 49.0 | 48.4 | 135.7 | 133.5 | — | 657,281 tokens |
| MTP, 2 tokens | 114.3 | 110.5 | 288.7 | 254.4 | 2.8 of 3 (~90% accepted) | 591,366 tokens |
| **MTP, 3 tokens (default)** | **134.1** | **132.0** | **324.5** | **286.3** | 3.6 of 4 (~86% accepted) | 587,722 tokens |
| MTP, 4 tokens | 145.8 | 137.7 | 347.2 | 263.3 | 4.2 of 5 (~80% accepted) | not recorded |

3 tokens is the default: 4 tokens is faster for a single conversation, but slower
with three sampled conversations in parallel, which is the normal agent workload.
The cost is ~10% of the KV cache pool (657K → 588K tokens), still 2.2 full 262K
contexts. Time to first token didn't change (~0.4 s).

vLLM warns that `num_speculative_tokens > 1` runs the single MTP layer several
times, which may lower acceptance. The per-position acceptance drops from ~95% for
the first draft token to ~67% for the fourth.

## Rerun

```bash
python3 bench/decode_bench.py http://hyperstack1.wg1:11434/v1/chat/completions baseline
ruby hyperstack.rb --vm 1 model switch qwen38-27b --no-speculative   # or back on
docker logs vllm_qwen38_27b 2>&1 | grep SpecDecoding                  # acceptance stats (on the VM)
```

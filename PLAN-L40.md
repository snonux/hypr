# Plan: VM1 on Hyperstack L40 with Qwen3.6 MoE + TurboQuant

**Prepared:** 2026-05-24  
**Scope:** Research and planning only — no code changes, no provisioning.

---

## 1. GPU and VM sizing (Hyperstack L40)

| Item | Assessment |
|---|---|
| **Flavor** | Hyperstack’s GPU flavors use the `n3-*` prefix (see current `n3-A100x1` / `n3-H100x1`). The L40 48 GB flavor is expected to be named `n3-L40x1` or `n3-L40Sx1`; exact string must be verified via the Hyperstack console/API before updating `hyperstack-vm1.toml`. |
| **VRAM** | 48 GB (vs 80 GB on the current A100). That is a hard ceiling for both model weights and KV cache. |
| **Cost** | L40/L40S nodes are generally cheaper than A100/H100 on Hyperstack. Assuming the tiered pricing model, an L40 should reduce the hourly cost of VM1, but the final price depends on the exact `flavor_name` and any egress charges. |

## 2. Model choice: what actually fits on 48 GB

The prompt mentions **Qwen3.6 MoE (e.g. 235B-A22B)**. A 235B-parameter model in BF16 would require **> 400 GB** of VRAM, which is impossible on a single L40. The only Qwen3.6 MoE that is publicly released and could *potentially* fit is **Qwen3.6-35B-A3B** (35B total / 3B active), but even that is **~70 GB in BF16**.

**Realistic options to make it fit in 48 GB:**

| Option | Weight size (est.) | Fit on 48 GB? | Notes |
|---|---|---|---|
| **AWQ 4-bit** Qwen3.6-35B-A3B | ~18 GB | Yes | Needs a community or official AWQ checkpoint (not yet listed as official at the time of writing, but AWQ/GPTQ variants usually appear quickly). |
| **FP8** Qwen3.6-35B-A3B (if available) | ~35 GB | Tight | Leaves ~10 GB for KV cache, activations and CUDA graphs. vLLM profiling may tip it over. |
| **Qwen3.6-27B dense** (current VM2 default) | ~27 GB FP8 | Yes | Not MoE; defeats the purpose of the task. |

**Recommendation:** Target an **AWQ 4-bit (or GPTQ 4-bit) Qwen3.6-35B-A3B** checkpoint, or wait for an official **FP8** checkpoint and accept a reduced `max_model_len`. Do not attempt the 235B-A22B variant on a single L40.

## 3. vLLM + TurboQuant compatibility

TurboQuant is a KV-cache compression backend in vLLM. Key upstream state:

- **PR #39931** (merged 2026-05-05) added TurboQuant support for *hybrid* architectures (attention + Mamba/MoE).
- **Issue #41726** reports a fatal crash during **chunked continuation prefill** on hybrid MoE models (e.g. Qwen3.5-9B NVFP4). Root cause: TurboQuant’s `_continuation_prefill` path requests workspace memory that was not reserved during warmup.
- **PR #40798** is open as a candidate fix but **not yet merged**.

**Implications for Qwen3.6-35B-A3B:**
- Because Qwen3.6 uses a hybrid attention+Mamba architecture, it is in the exact class of models affected by #41726.
- If TurboQuant is enabled (`--kv-cache-dtype turboquant_k8v4`, `--kv-cache-dtype turboquant_4bit_nc`, etc.), any long prompt that crosses a chunked-prefill boundary will likely trigger:
  ```
  AssertionError: Workspace is locked but allocation ... requires X MB, current size is Y MB.
  ```

**Mitigations available today:**
1. **Disable chunked prefill:** Pass `--no-enable-chunked-prefill` in `extra_vllm_args`. This avoids the `_continuation_prefill` path entirely. Trade-off: large prefills are no longer split into chunks, which can increase latency for long inputs and may OOM if a single prefill is very large.
2. **Use `--enforce-eager`:** Disables CUDA graph capture, which slightly changes memory layout but does **not** solve the workspace lock issue by itself. It is useful mainly to save a few GB of VRAM on tight GPUs.
3. **Wait for PR #40798** to merge and land in a stable vLLM image.

## 4. Recommended `hyperstack-vm1.toml` changes (conceptual)

```toml
[vm]
# Verify exact flavor string with Hyperstack API before deploying.
flavor_name = "n3-L40x1"          # or n3-L40Sx1
labels = ["qwen36-moe", "wireguard"]

[vllm]
install = true
model = "Qwen/Qwen3.6-35B-A3B-AWQ"   # or the best available quantized MoE
container_name = "vllm_qwen36_moe"
max_model_len = 65536                  # conservative for 48 GB; can raise if AWQ
gpu_memory_utilization = 0.92
tensor_parallel_size = 1
tool_call_parser = "qwen3_coder"

# TurboQuant KV cache on a hybrid MoE
extra_vllm_args = [
  "--reasoning-parser", "qwen3",
  "--kv-cache-dtype", "turboquant_k8v4",
  "--no-enable-chunked-prefill"        # mitigation for issue #41726
]

# Nightly image post-PR-39931 is required; pin to a known-good digest until 0.20.2+
docker_image = "vllm/vllm-openai:nightly"
```

**VRAM estimate (AWQ 4-bit + TurboQuant K8V4 on L40 48 GB):**

| Consumer | Est. size |
|---|---|
| AWQ weights (35B params @ 4-bit) | ~18 GB |
| Activations / MoE routing / logits | ~4–6 GB |
| CUDA graphs (if not eager) | ~2 GB |
| KV cache (TurboQuant) | ~20–24 GB |
| **Headroom** | **~0–4 GB** |

Because headroom is thin, `gpu_memory_utilization=0.92` is appropriate. If profiling OOMs, raise it to `0.95` or drop `max_model_len`. If vLLM still OOMs during startup, try `--enforce-eager` to reclaim the CUDA-graph memory.

## 5. CLI and WireGuard implications

| Area | Impact |
|---|---|
| `--vm 1 / 2 / both` | No structural changes. The CLI already resolves `hyperstack-vm1.toml` independently via its own state file. Switching the flavor/model is transparent to `--vm 2`. |
| WireGuard | `wireguard_server_ip = "192.168.3.1"` stays the same. Recreating VM1 yields a new public IP, so the local `wg1.conf` peer endpoint must be refreshed (`ruby hyperstack.rb --vm 1 create` already handles this via `wg1-setup.sh`). The tunnel subnet `192.168.3.0/24` is unchanged. |
| Port 11434 / firewall | Unchanged. Port 56710 UDP and 22 TCP remain locked to `allowed_wireguard_cidrs` / `allowed_ssh_cidrs`. |
| Dual-VM routing | The client can continue to round-robin or fallback between `192.168.3.1` (VM1, MoE) and `192.168.3.3` (VM2, dense). No code changes needed. |

## 6. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **TurboQuant crash (#41726)** on hybrid MoE | High | Disable chunked prefill now; migrate to fixed vLLM nightly once PR #40798 lands. |
| **Model does not fit** in 48 GB if no AWQ/FP8 checkpoint exists | High | Confirm a 4-bit or FP8 checkpoint is on HuggingFace before provisioning. Fallback to Qwen3.6-27B dense (moves goalposts). |
| **Performance regression** from no chunked prefill | Medium | Expect higher TTFB on long prompts. Monitor with `ruby hyperstack.rb --vm 1 test`. |
| **Flavor unavailability** | Medium | Have a fallback flavor ready (e.g. `n3-A100x1` on VM1 if L40 is sold out), or accept A100 pricing. |
| **Nightly Docker image instability** | Medium | Pin to a specific digest (`vllm/vllm-openai@sha256:...`) after first successful smoke test. |

## 7. Step-by-step migration plan (if you decide to proceed)

1. **Verify asset availability**
   - Confirm Hyperstack offers an L40 flavor and note its exact name.
   - Locate a Qwen3.6-35B-A3B AWQ/FP8 checkpoint on HuggingFace. If none exists, abort or pivot to the dense 27B.

2. **Snapshot / backup**
   - Ensure VM2 (A100 dense) is stable and passing tests (`ruby hyperstack.rb --vm 2 test`).
   - Save current VM1 state file as `.hyperstack-vm1-state.json.bak` in case a fast rollback is needed.

3. **Update configuration**
   - Edit `hyperstack-vm1.toml`:
     - `flavor_name` → L40 flavor.
     - `[vllm]` block → new model ID, container name, conservative `max_model_len`.
     - Add `docker_image = "vllm/vllm-openai:nightly"` (or a pinned digest).
     - Add TurboQuant arg and chunked-prefill mitigation to `extra_vllm_args`.
   - Update `[vm] labels` to reflect the new model.

4. **Provision**
   ```bash
   ruby hyperstack.rb --vm 1 create --replace
   ```
   The `--replace` flag tears down the old A100 VM1 and rebuilds it on L40.

5. **Post-create validation**
   - Check WireGuard handshake: `sudo wg show wg1 latest-handshakes`.
   - Ping tunnel IP: `ping -c 3 192.168.3.1`.
   - Query vLLM: `curl -s http://192.168.3.1:11434/v1/models`.
   - Run the automated test suite: `ruby hyperstack.rb --vm 1 test`.

6. **Smoke test for TurboQuant stability**
   - Send a conversation with a very long system prompt (> 4096 tokens) and tool schemas to force a chunked-prefill boundary.
   - If the engine crashes with the workspace assertion, apply the fallback:
     - Add `--enforce-eager` to `extra_vllm_args`, or
     - Fall back to `--kv-cache-dtype fp8` (loses TurboQuant compression but is stable).

7. **Dual-VM confirmation**
   - Run `ruby hyperstack.rb --vm both test` to ensure both endpoints are healthy and reachable through the WireGuard tunnel.

8. **Monitor and iterate**
   - Watch VRAM usage with `nvidia-smi` inside the VM.
   - Adjust `max_model_len` and `gpu_memory_utilization` as needed.
   - Once upstream PR #40798 merges, rebuild the Docker image with the fixed vLLM version and re-enable chunked prefill.

---

## Bottom line

The L40 is a cost-efficient target *if* a quantized Qwen3.6-35B-A3B checkpoint is available. The biggest blocker is the open vLLM issue #41726 (TurboQuant + hybrid MoE crash on chunked prefill). Disabling chunked prefill is a viable short-term workaround, but it comes with a latency trade-off and must be validated before making VM1 the default endpoint.

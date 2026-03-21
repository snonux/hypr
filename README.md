# hyperstack

Automates Hyperstack GPU VM lifecycle: create, bootstrap, WireGuard tunnel, and vLLM inference.
Runs two A100 VMs concurrently — each serving a different model — with [Pi](https://pi.dev) coding agents connected to each.

## Architecture

```
                        WireGuard tunnel (wg1, 192.168.3.0/24)
                        earth = .2 ──────────────────────────────────────────┐
                                │                                            │
         ┌──────────────────────┼────────────────────────────────────────────┐│
         │                      │                                            ││
         ▼                      ▼                                            ▼▼
  Hyperstack VM1 (A100 80GB)         Hyperstack VM2 (A100 80GB)
  192.168.3.1 / hyperstack1.wg1      192.168.3.3 / hyperstack2.wg1
  ┌──────────────────────────────┐    ┌──────────────────────────────────┐
  │ vLLM (:11434)                │    │ vLLM (:11434)                    │
  │   Nemotron-3-Super 120B      │    │   Qwen3-Coder-Next 80B (MoE)    │
  │   (hybrid Mamba+MoE, AWQ-4b) │    │   (AWQ-4bit)                     │
  └──────────────────────────────┘    └──────────────────────────────────┘
         ▲                                     ▲
         │ OpenAI /v1/chat/completions         │ OpenAI /v1/chat/completions
         │                                     │
  ┌──────┴──────┐                       ┌──────┴──────┐
  │ Pi (local)  │                       │ Pi (local)  │
  │ ./pi-vm1    │                       │ ./pi-vm2    │
  │ Nemotron 3  │                       │ Qwen3 Coder │
  └─────────────┘                       └─────────────┘
```

Both VMs share a single WireGuard interface (`wg1`) on the local machine.
Each VM runs one vLLM model exposed directly to Pi over the OpenAI-compatible API.

## Prerequisites

- Hyperstack account with API key in `~/.hyperstack`
- SSH key registered in Hyperstack as `earth` (or change `ssh.hyperstack_key_name` in the TOML)
- Review `[network].allowed_ssh_cidrs` and `[network].allowed_wireguard_cidrs` in your TOML.
  The secure default is `["auto"]`, which resolves your current public egress IP to `/32`.
  Set explicit CIDRs or `HYPERSTACK_OPERATOR_CIDR` if you deploy from a different network.
- WireGuard setup script: `wg1-setup.sh` (present in this directory)
- Ruby with `toml-rb` gem: `bundle install`
- [Pi](https://pi.dev) coding agent installed

## Quickstart (two-VM setup)

```bash
# Deploy both VMs in parallel, set up WireGuard + vLLM (~10 min)
ruby hyperstack.rb create-both

# Verify both VMs are working
ruby hyperstack.rb --config hyperstack-vm1.toml test
ruby hyperstack.rb --config hyperstack-vm2.toml test

# Launch Pi coding agents — one per terminal
./pi-vm1   # Nemotron-3-Super 120B on VM1
./pi-vm2   # Qwen3-Coder-Next on VM2

# Tear down both VMs
ruby hyperstack.rb delete-both
```

## Using Pi

Pi is the primary coding agent frontend. Each VM has a wrapper script that launches Pi
with the correct model routed to that VM's vLLM instance.

Bring both VMs up first:

```bash
ruby hyperstack.rb create-both
```

Then start one Pi session per terminal:

```bash
./pi-vm1   # → hyperstack1/cyankiwi/NVIDIA-Nemotron-3-Super-120B-A12B-AWQ-4bit
./pi-vm2   # → hyperstack2/bullpoint/Qwen3-Coder-Next-AWQ-4bit
```

These wrappers `cd` into this repo before launching Pi, so the project-local
settings in `pi/agent/settings.json` and model definitions in `pi/agent/models.json` apply.

Pi model definitions are in `pi/agent/models.json` — two providers (`hyperstack1`, `hyperstack2`)
are configured, each pointing at its VM's vLLM endpoint over WireGuard. All model presets
from the TOML configs are registered so you can hot-switch models within Pi using `model switch`.

**Fish shell abbreviations** (see `hyperstack.fish`):

```fish
abbr pi-hyperstack-nemotron pi --model hyperstack1/cyankiwi/NVIDIA-Nemotron-3-Super-120B-A12B-AWQ-4bit
abbr pi-hyperstack-coder    pi --model hyperstack2/bullpoint/Qwen3-Coder-Next-AWQ-4bit
```

## Single-VM setup

A single VM can be deployed with the default config:

```bash
ruby hyperstack.rb create                # uses hyperstack-vm.toml
ruby hyperstack.rb test
ruby hyperstack.rb delete
```

## VM configuration

| Config file | Default model | WireGuard IP | Hostname |
|---|---|---|---|
| `hyperstack-vm1.toml` | Nemotron-3-Super 120B (AWQ-4bit) | `192.168.3.1` | `hyperstack1.wg1` |
| `hyperstack-vm2.toml` | Qwen3-Coder-Next 80B (AWQ-4bit) | `192.168.3.3` | `hyperstack2.wg1` |
| `hyperstack-vm.toml` | Qwen3-Coder-Next (single-VM mode) | `192.168.3.1` | `hyperstack.wg1` |

Each VM has independent state files so they can be managed separately:

```bash
ruby hyperstack.rb --config hyperstack-vm1.toml status
ruby hyperstack.rb --config hyperstack-vm2.toml status
```

## Switching models

Each VM has named model presets in its TOML config. Hot-switch without reprovisioning:

```bash
ruby hyperstack.rb --config hyperstack-vm1.toml model switch qwen3-coder-next
ruby hyperstack.rb --config hyperstack-vm2.toml model switch nemotron-super
```

Available presets (both VMs share the same set):

| Preset | Model | VRAM | Context |
|---|---|---|---|
| `nemotron-super` | Nemotron-3-Super 120B (Mamba+MoE, 12B active) | ~60 GB | 262K |
| `qwen3-coder-next` | Qwen3-Coder-Next 80B (MoE, AWQ-4bit) | ~45 GB | 262K |
| `gpt-oss-120b` | GPT-OSS 120B (MoE, MXFP4) | ~65 GB | 131K |
| `gpt-oss-20b` | GPT-OSS 20B (MoE, MXFP4) | ~14 GB | 65K |
| `qwen25-coder-32b` | Qwen2.5-Coder-32B-Instruct (AWQ) | ~18 GB | 32K |
| `qwen3-coder-30b` | Qwen3-Coder-30B-A3B (MoE, AWQ) | ~18 GB | 65K |
| `deepseek-r1-32b` | DeepSeek-R1-Distill-Qwen-32B (AWQ) | ~18 GB | 32K |
| `qwen3-32b` | Qwen3-32B (AWQ) | ~18 GB | 32K |
| `devstral` | Devstral-Small-2507 (AWQ-4bit) | ~15 GB | 32K |

## CLI reference

```
ruby hyperstack.rb [--config path] <command> [options]

Commands:
  create       Deploy a new VM and run full provisioning
  create-both  Deploy VM1 + VM2 in parallel (uses hyperstack-vm1/vm2.toml)
  delete       Destroy the tracked VM
  delete-both  Destroy both VM1 and VM2
  status       Show VM and WireGuard status
  test         Run end-to-end inference tests (vLLM)
  model switch <preset>  Hot-switch the running vLLM model

create / create-both options:
  --replace          Delete existing tracked VM before creating
  --dry-run          Print the plan without making changes
  --vllm / --no-vllm    Override config: enable/disable vLLM setup
  --ollama / --no-ollama Override config: enable/disable Ollama setup
```

## Configuration

Edit `hyperstack-vm1.toml` / `hyperstack-vm2.toml` (or `hyperstack-vm.toml` for single-VM).
Key sections:

| Section | Purpose |
|---------|---------|
| `[vm]` | Flavor, image, environment name |
| `[vllm]` | Model, container settings, and vLLM runtime options |
| `[vllm.presets.*]` | Named model presets for hot-switching |
| `[ollama]` | Ollama settings (disabled by default; set `install = true` to use instead) |
| `[network]` | Ports, WireGuard subnet, allowed CIDRs |
| `[wireguard]` | Auto-setup script path |

`allowed_ssh_cidrs` and `allowed_wireguard_cidrs` accept either explicit CIDRs such as
`["203.0.113.4/32"]` or `["auto"]`. `auto` resolves the current public operator IP at runtime;
set `HYPERSTACK_OPERATOR_CIDR` to override that detection when needed.

SSH host keys are pinned per state file in `<state>.known_hosts`. `delete` and `--replace`
clear that trust file for intentional reprovisioning; unexpected host key changes now fail closed.

## Why vLLM instead of Ollama

- **FlashAttention v2**: ~1.5–2× faster prefill for long prompts
- **Block-level prefix caching**: partial KV cache reuse even when the prompt changes mid-sequence (Ollama requires an exact prefix match from token 0)
- **Chunked prefill**: can interleave prefill and decode
- **Marlin kernels** for AWQ MoE quantization

## Monitoring vLLM

```bash
# Live engine stats (throughput, KV cache, prefix cache hit rate)
ssh ubuntu@<vm-ip> 'docker logs -f vllm_nemotron_super 2>&1 | grep "Engine 000"'

# GPU stats (every 5 s)
ssh ubuntu@<vm-ip> 'nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,power.draw,memory.used --format=csv -l 5'

# Last-minute stats (one-shot, no follow)
ssh ubuntu@<vm-ip> 'docker logs --since 1m vllm_nemotron_super 2>&1 | grep "Engine 000"'

# Request-level monitoring
ssh ubuntu@<vm-ip> 'docker logs -f vllm_nemotron_super 2>&1 | grep "POST"'
```

Engine metrics key fields:

| Field | Meaning |
|-------|---------|
| Avg prompt throughput | Prefill speed (tokens/s) — higher is faster |
| Avg generation throughput | Decode speed (tokens/s) — ~40–99 on A100 PCIe |
| GPU KV cache usage | % of KV cache memory in use (proportional to active context vs max capacity) |
| Prefix cache hit rate | % of prompt tokens served from cache |
| Running / Waiting | Active and queued request counts |

Healthy baseline (A100 80GB PCIe):

| Metric | Expected |
|--------|----------|
| Prefill throughput | 5,000–11,000 tok/s |
| Decode throughput | 40–99 tok/s |
| KV cache usage | 2–5% for typical sessions |
| Temperature | 44–60°C under load, <45°C idle |
| Power | 70 W idle, 230–240 W under load, 300 W max |

Warning signs:

- **Waiting > 0 for extended periods** — requests queuing, model overloaded
- **KV cache usage near 100%** — context too long, reduce `--max-model-len`
- **Decode throughput < 20 tok/s sustained** — possible thermal throttling
- **Prefill throughput < 2,000 tok/s** — check for CPU offload or driver issues

## Troubleshooting

| Problem | Fix |
|---------|-----|
| OOM on startup with `--max-model-len 262144` | Reduce to `131072` or `65536` |
| Prefix cache hit rate stays at 0% | Normal when prompts vary heavily turn-to-turn |
| vLLM container won't start (CUDA mismatch) | Check `nvidia-smi`; vLLM requires CUDA ≥ 12.x and driver ≥ 535 |
| Still OOM after reducing context | Lower `gpu_memory_utilization` to `0.85` or use a smaller model |

## VRAM sizing guide

Rule of thumb for a single A100 80 GB at 92% utilization (~75 GiB usable):

| Model size (params) | AWQ 4-bit VRAM | Max context (remaining for KV) |
|---|---|---|
| 7–8B | ~5 GiB | 262k+ (plenty of KV headroom) |
| 14B | ~9 GiB | 262k+ (plenty of KV headroom) |
| 30–32B | ~18 GiB | 262k (~57 GiB for KV cache) |
| 70–80B (MoE, 3B active) | ~45 GiB | 262k (~27 GiB for KV cache) |
| 70B (dense) | ~38 GiB | 131k (~37 GiB for KV cache) |
| 120B+ | won't fit | use multi-GPU or smaller quant |

Supported quantization formats:

- **AWQ** (recommended): fast Marlin kernels, good quality
- **GPTQ**: similar to AWQ, widely available
- **FP8**: 8-bit, needs Hopper+ GPUs (H100/H200)
- **BF16/FP16**: full precision, needs more VRAM

Search HuggingFace for vLLM-compatible quantized models:
`https://huggingface.co/models?search=<model-name>+awq`

## Performance characteristics

Measured on A100 80 GB PCIe (single GPU) with Qwen3-Coder-Next AWQ 4-bit:

| Metric | vLLM (AWQ 4-bit) | Ollama (Q4_K_M) |
|--------|-------------------|-----------------|
| Prefill throughput | 5,000–11,000 tok/s | ~1,000 tok/s (est.) |
| Decode throughput | 40–99 tok/s | ~40 tok/s |
| Per-turn latency | ~10–15 s | ~28 s (32k ctx) |
| Context window | 262k (full, no truncation) | 32k (was truncating) |
| VRAM usage | 75 GiB (more KV cache) | 52–61 GiB |

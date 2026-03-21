# hyperstack

Automates Hyperstack GPU VM lifecycle: create, bootstrap, WireGuard tunnel, vLLM inference, LiteLLM proxy.

## Architecture

```
Claude Code (local)                    Hyperstack VM (A100 80GB)
┌─────────────────┐                   ┌──────────────────────────────────┐
│ claude CLI       │── Anthropic API ─▶│ LiteLLM proxy (:4000)           │
│                  │   /v1/messages    │   Anthropic → OpenAI translation │
│                  │   via WireGuard   │             │                    │
└─────────────────┘                   │             ▼                    │
                                      │ vLLM engine (:11434)            │
OpenCode (local)                      │   bullpoint/Qwen3-Coder-Next-   │
┌─────────────────┐                   │   AWQ-4bit (45 GB, MoE 80B)     │
│ opencode         │── OpenAI API ────▶│   FlashAttention v2             │
│                  │   /v1/chat/...    │   prefix caching                │
└─────────────────┘                   └──────────────────────────────────┘
```

Both local clients connect over a WireGuard tunnel (`wg1`, subnet `192.168.3.0/24`).
The VM gets `192.168.3.1`; your local machine gets `192.168.3.2`.

## Prerequisites

- Hyperstack account with API key in `~/.hyperstack`
- SSH key registered in Hyperstack as `earth` (or change `ssh.hyperstack_key_name` in the TOML)
- Review `[network].allowed_ssh_cidrs` and `[network].allowed_wireguard_cidrs` in your TOML.
  The secure default is `["auto"]`, which resolves your current public egress IP to `/32`.
  Set explicit CIDRs or `HYPERSTACK_OPERATOR_CIDR` if you deploy from a different network.
- WireGuard setup script: `wg1-setup.sh` (present in this directory)
- Ruby with `toml-rb` gem: `bundle install`

## Quickstart

```bash
# Deploy VM, set up WireGuard + vLLM + LiteLLM (~10 min on first run)
ruby hyperstack.rb create

# Verify everything is working
ruby hyperstack.rb test

# Use Claude Code against the local vLLM
ANTHROPIC_BASE_URL=http://hyperstack.wg1:4000 \
ANTHROPIC_API_KEY=sk-litellm-master \
claude --model claude-opus-4-6-20260604 --dangerously-skip-permissions

# Tear down
# Also removes the tracked local wg1 peer, hostname alias, and pinned SSH host key.
ruby hyperstack.rb delete
```

## Using Pi

Bring both VMs up first:

```bash
ruby hyperstack.rb create-both
```

Then start one Pi session per terminal:

```bash
./pi-vm1
./pi-vm2
```

These wrappers `cd` into this repo before launching Pi, so the project-local
settings in `.pi/settings.json` still apply.

## Using Claude Code with vLLM

WireGuard (`wg1`) must be active before connecting.

```bash
ANTHROPIC_BASE_URL=http://hyperstack.wg1:4000 \
ANTHROPIC_API_KEY=sk-litellm-master \
claude --model claude-opus-4-6-20260604 --dangerously-skip-permissions
```

If you see an **"Auth conflict"** warning, clear the saved claude.ai session first:

```bash
claude /logout
```

**Fish shell alias** (add to `~/.config/fish/config.fish`):

```fish
alias claude-local='ANTHROPIC_BASE_URL=http://hyperstack.wg1:4000 \
  ANTHROPIC_API_KEY=sk-litellm-master \
  claude --model claude-opus-4-6-20260604 --dangerously-skip-permissions'
```

**Available model aliases** — all map to the same vLLM model:

| Alias | Use case |
|-------|----------|
| `claude-opus-4-6-20260604` | Recommended (most future-proof) |
| `claude-opus-4-20250514` | |
| `claude-sonnet-4-20250514` | |
| `claude-haiku-3-5-20241022` | |

Add new Anthropic model IDs to `vllm.litellm_claude_model_names` in `hyperstack-vm.toml` as they are released.

## Using OpenCode with vLLM

OpenCode speaks OpenAI natively — connect directly to vLLM, no LiteLLM needed:

```bash
OPENAI_BASE_URL=http://hyperstack.wg1:11434/v1 \
OPENAI_API_KEY=EMPTY \
opencode
```

Set the model name to `bullpoint/Qwen3-Coder-Next-AWQ-4bit` in your OpenCode config.

## CLI reference

```
ruby hyperstack.rb [--config path] <command> [options]

Commands:
  create   Deploy a new VM and run full provisioning
  delete   Destroy the tracked VM
  status   Show VM and WireGuard status
  test     Run end-to-end inference tests (vLLM + LiteLLM)

create options:
  --replace          Delete existing tracked VM before creating
  --dry-run          Print the plan without making changes
  --vllm / --no-vllm    Override config: enable/disable vLLM+LiteLLM setup
  --ollama / --no-ollama Override config: enable/disable Ollama setup
```

## Configuration

Edit `hyperstack-vm.toml` to change defaults. Key sections:

| Section | Purpose |
|---------|---------|
| `[vm]` | Flavor, image, environment name |
| `[vllm]` | Model, container settings, LiteLLM key and Claude aliases |
| `[ollama]` | Ollama settings (disabled by default; set `install = true` to use instead) |
| `[network]` | Ports, WireGuard subnet, allowed CIDRs |
| `[wireguard]` | Auto-setup script path |

`allowed_ssh_cidrs` and `allowed_wireguard_cidrs` accept either explicit CIDRs such as
`["203.0.113.4/32"]` or `["auto"]`. `auto` resolves the current public operator IP at runtime;
set `HYPERSTACK_OPERATOR_CIDR` to override that detection when needed.

SSH host keys are pinned per state file in `<state>.known_hosts`. `delete` and `--replace`
clear that trust file for intentional reprovisioning; unexpected host key changes now fail closed.

## Monitoring vLLM

```bash
# Live engine stats (throughput, KV cache, prefix cache hit rate)
ssh ubuntu@<vm-ip> 'docker logs -f vllm_qwen3 2>&1 | grep "Engine 000"'

# Last 1 minute of stats
ssh ubuntu@<vm-ip> 'docker logs --since 1m vllm_qwen3 2>&1 | grep "Engine 000"'

# GPU stats (every 5 s)
ssh ubuntu@<vm-ip> 'nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,power.draw,memory.used --format=csv -l 5'

# LiteLLM proxy log
ssh ubuntu@<vm-ip> 'sudo journalctl -fu litellm'
```

Healthy baseline (A100 80GB PCIe, qwen3-coder-next AWQ 4-bit):

| Metric | Expected |
|--------|----------|
| Prefill throughput | 5,000–11,000 tok/s |
| Decode throughput | 40–99 tok/s |
| KV cache usage | 2–5% for typical sessions |
| Prefix cache hit (Claude Code) | 0% (expected — prompt prefix mutates each turn) |
| Prefix cache hit (OpenCode) | >50% after warm-up |

## Switching models

Stop the current container, start a new one with a different `--model`, then update `vllm.model` in `hyperstack-vm.toml` and re-run `ruby hyperstack.rb create` to reinstall LiteLLM with the updated config.

See `vllm-setup.txt` for detailed vLLM and LiteLLM setup notes, VRAM sizing guide, and troubleshooting.

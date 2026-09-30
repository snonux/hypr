# AGENTS.md — Operational runbook for hypr

This file is the index to the operational runbook for the Hyperstack VM + WireGuard +
vLLM setup. Detailed procedures live in `docs/`; see README.md for architecture and
configuration reference.

## Runbook topics

| Doc | Covers |
|-----|--------|
| [docs/gpu-flavors.md](docs/gpu-flavors.md) | A100 first, H100 fallback — manual flavor switch procedure |
| [docs/create-troubleshooting.md](docs/create-troubleshooting.md) | Docker image pull EOF failures, resuming a failed `create`, `--replace` |
| [docs/wireguard.md](docs/wireguard.md) | `wg1 already exists`, stale public keys / no handshake, end-to-end tunnel verification, Hyperstack firewall rules |
| [docs/vllm-startup.md](docs/vllm-startup.md) | Container startup phases, readiness monitoring, harmless CUDA errors |
| [docs/state-file.md](docs/state-file.md) | `.hyperstack-vmN-state.json` fields and what they mean |
| [docs/speculative-decoding.md](docs/speculative-decoding.md) | MTP speculative decoding for Qwen3.8: config, `--no-speculative`, benchmark results |
| [docs/pi-model-costs.md](docs/pi-model-costs.md) | Why pi's status-bar cost drifts from OpenRouter prices and how to fix it |

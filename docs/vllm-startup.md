# vLLM container startup sequence

After the Docker container starts, the model goes through several phases before
inference is ready. On an H100 with a warm HuggingFace cache:

| Phase | Duration | Log signal |
|-------|----------|------------|
| Docker pull (first time) | ~2–3 min | Layer progress bars |
| Model download from HuggingFace (first time) | ~3–5 min | `Downloading...` |
| Weight loading | ~4–5 s | `Loading safetensors checkpoint shards: 100%` |
| torch.compile + CUDA graph capture | ~2–4 min | `torch.compile took X s` |
| **Ready** | — | `Application startup complete.` |

Qwen3.8-27B-FP8 on an H100 takes ~5 min from container start to ready on a warm
cache; cold start (first run, no HuggingFace cache) can take 10+ minutes. The
provisioning script waits up to 30 minutes (360 × 5 s) for the API to respond.

If `create` fails because the readiness poll timed out but the container is
still running, re-running `create` will detect the running container and skip
the restart — it goes straight to the readiness check.

**Monitor startup:**

```bash
ssh ubuntu@<vm-public-ip> 'sudo docker logs -f vllm_qwen38_27b 2>&1' \
    | grep -E "startup complete|Error|Loading|Downloading"
```

After `Application startup complete.`, the model responds immediately.
If the container crashes before that line, check for CUDA errors:

```bash
ssh ubuntu@<vm-public-ip> 'sudo docker logs vllm_qwen38_27b 2>&1 | grep -i "error\|cuda"'
```

A `CUDA error: operation not permitted` on the first engine process (pid visible in
logs) is harmless if a second engine process starts successfully right after — vLLM
retries internally.

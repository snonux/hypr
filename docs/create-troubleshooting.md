# Troubleshooting `create`: Docker pull failures and resuming

## Docker image pull failures (transient EOF)

The `vllm/vllm-openai:latest` image is ~20 GB. Docker Hub occasionally drops the
connection mid-layer with:

```
failed to extract layer ... EOF
```

The provisioner retries twice automatically. If all attempts fail, just re-run create:

```bash
ruby hyperstack.rb --vm 2 create
```

The VM already exists and is tracked in the state file; `create` resumes from where it
left off (skips VM creation, goes straight to vLLM setup). Docker will retry the pull
from scratch and usually succeeds on the next attempt.

## Resuming a failed `create`

If `create` exits non-zero partway through (e.g. WireGuard retries exhausted, vLLM
readiness timeout, Docker EOF), the VM is still running and the state file tracks it.
Re-running `create` will skip already-completed steps and, if the vLLM container is
already running and healthy, will skip the restart entirely.

```bash
ruby hyperstack.rb --vm 2 create
```

The script checks `vllm_setup_at` and `bootstrapped_at` in the state file and skips
already-completed steps. Typical resume flow:

- VM already exists → skips VM creation
- `bootstrapped_at` set → skips guest bootstrap
- `vllm_setup_at` nil → runs vLLM Docker setup

If you want to force a full reprovision from scratch:

```bash
ruby hyperstack.rb --vm 2 create --replace
```

This deletes the existing VM, clears the state file, and starts over.

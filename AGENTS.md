# AGENTS.md — Operational runbook for hypr

This file documents known startup issues, workarounds, and diagnostic procedures
for the Hyperstack VM + WireGuard + vLLM setup. See README.md for architecture and
configuration reference.

---

## GPU flavor availability: A100 first, H100 fallback

The A100 80GB (`n3-A100x1`) is cheaper but sometimes sold out.
The H100 80GB (`n3-H100x1`) is the fallback.

**Manual fallback procedure:**

1. Edit the TOML and try A100 first:
   ```toml
   # hyperstack-vm2.toml
   flavor_name = "n3-A100x1"
   ```
2. Run `ruby hyperstack.rb --vm 2 create`.
3. If the API returns a flavor-not-available error, switch to H100:
   ```toml
   flavor_name = "n3-H100x1"
   ```
4. Re-run create. The state file is only written after the VM is successfully created,
   so a failed create leaves nothing to clean up.

Both GPUs have 80 GB VRAM and run all presets identically.
The TOML comment above `flavor_name` tracks the current choice.

---

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

---

## WireGuard tunnel issues on first VM start

After `create`, the WireGuard tunnel is set up by `wg1-setup.sh`. Several things can
go wrong on the first attempt.

### Symptom: `wg1 already exists`

The systemd service fails with:

```
wg-quick: `wg1' already exists
```

This means the interface was brought up manually by the setup script but systemd
subsequently tried to bring it up again and failed. The interface is actually running,
but systemd thinks the service is failed.

**Fix:**

```bash
# Check the interface is actually up
sudo wg show wg1

# If the peer is listed correctly, just reload systemd state
sudo systemctl reset-failed wg-quick@wg1

# If the peer is wrong or missing, drop and restart
sudo ip link delete wg1
sudo systemctl start wg-quick@wg1
```

### Symptom: tunnel up but no handshake (0 bytes received)

```bash
sudo wg show wg1 latest-handshakes
# shows timestamp 0 for a peer
```

The most common cause after recreating a VM is a **stale public key** in the local
`/etc/wireguard/wg1.conf`. When a VM is deleted and recreated, it generates fresh
WireGuard keys. The setup script writes the new key, but if the script ran with
errors (e.g. WireGuard retry failures during `create`), the local conf may still
contain the old VM's public key.

**Diagnose:**

```bash
# Get the VM's actual current public key
ssh ubuntu@<vm-public-ip> 'sudo wg show wg1 public-key'

# Compare to what's in the local conf
grep PublicKey /etc/wireguard/wg1.conf
```

**Fix a key mismatch:**

```bash
# Replace the stale key in the local conf (substitute correct values)
STALE_KEY="<old-key-from-conf>"
NEW_KEY="<actual-key-from-vm>"
VM_IP="<vm-public-ip>"
VM_WG_IP="192.168.3.3"   # .1 for VM1, .3 for VM2

sudo sed -i "s|PublicKey = ${STALE_KEY}|PublicKey = ${NEW_KEY}|" /etc/wireguard/wg1.conf

# Apply the new peer live without restarting the interface
sudo wg set wg1 peer ${NEW_KEY} endpoint ${VM_IP}:56710 \
    allowed-ips ${VM_WG_IP}/32 persistent-keepalive 25

# Remove the stale peer entry
sudo wg set wg1 peer ${STALE_KEY} remove

# Verify handshake within ~5 s
sleep 5 && sudo wg show wg1 latest-handshakes
```

### Verify the tunnel end-to-end

After fixing any of the above:

```bash
# 1. Confirm handshake timestamp is recent (non-zero, within last 30 s)
sudo wg show wg1 latest-handshakes

# 2. Ping through the tunnel
ping -c 3 192.168.3.3   # VM2; use 192.168.3.1 for VM1

# 3. Confirm vLLM is reachable over the tunnel
curl -s http://192.168.3.3:11434/v1/models | python3 -c \
    "import sys,json; print([m['id'] for m in json.load(sys.stdin)['data']])"

# 4. Full automated test
ruby hyperstack.rb --vm 2 test
```

Note: `curl` to the public IP will time out — port 11434 is firewalled to
the WireGuard subnet (`192.168.3.0/24`) only. Always use the WireGuard IP.

---

## vLLM container startup sequence

After the Docker container starts, the model goes through several phases before
inference is ready. On an A100 with a warm HuggingFace cache:

| Phase | Duration | Log signal |
|-------|----------|------------|
| Docker pull (first time) | ~2–3 min | Layer progress bars |
| Model download from HuggingFace (first time) | ~3–5 min | `Downloading...` |
| Weight loading | ~47 s | `Loading safetensors checkpoint shards: 100%` |
| torch.compile + CUDA graph capture | ~1–2 min | `torch.compile took X s` |
| **Ready** | — | `Application startup complete.` |

**Monitor startup:**

```bash
ssh ubuntu@<vm-public-ip> 'sudo docker logs -f vllm_qwen36_27b 2>&1' \
    | grep -E "startup complete|Error|Loading|Downloading"
```

After `Application startup complete.`, the model responds immediately.
If the container crashes before that line, check for CUDA errors:

```bash
ssh ubuntu@<vm-public-ip> 'sudo docker logs vllm_qwen36_27b 2>&1 | grep -i "error\|cuda"'
```

A `CUDA error: operation not permitted` on the first engine process (pid visible in
logs) is harmless if a second engine process starts successfully right after — vLLM
retries internally.

---

## Resuming a failed `create`

If `create` exits non-zero partway through (e.g. WireGuard retries exhausted, Docker
EOF), the VM is still running and the state file tracks it. Simply re-run:

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

---

## WireGuard firewall rules (Hyperstack security group)

Port 56710/udp and port 22/tcp are locked to `allowed_wireguard_cidrs` and
`allowed_ssh_cidrs` respectively. These default to `["auto"]`, which resolves your
current public egress IPv4 at creation time.

If your IP changes after creation (e.g. ISP reassignment), the Hyperstack firewall
will block your handshake attempts silently. Symptoms: UDP reachable via `nc -zu` but
WireGuard still shows 0 bytes received and timestamp 0.

**Check what IP is in the Hyperstack rule:**

```bash
python3 -c "
import json
d = json.load(open('.hyperstack-vm2-state.json'))
for r in d.get('security_rules', []):
    if r.get('port_range_min') in (22, 56710):
        print(r['protocol'], r['port_range_min'], r['remote_ip_prefix'])
"
```

**Check your current IPv4:**

```bash
curl -s -4 https://ifconfig.me
```

If they differ, update the Hyperstack security group via the web console or re-run
`create --replace` so the rules are refreshed with the new IP.

---

## Checking the state file

The JSON state file (`.hyperstack-vm2-state.json` for VM2) is the source of truth
for provisioning state. Key fields:

```bash
python3 -c "
import json
d = json.load(open('.hyperstack-vm2-state.json'))
print('vm_id:          ', d.get('vm_id'))
print('public_ip:      ', d.get('public_ip'))
print('bootstrapped_at:', d.get('bootstrapped_at'))
print('vllm_setup_at:  ', d.get('vllm_setup_at'))
print('vllm_model:     ', d.get('vllm_model'))
"
```

If `vllm_setup_at` is `None` but the container is running, the provisioner did not
mark setup as complete (likely a transient error at the end of `create`). Re-running
`create` will redo the vLLM step.

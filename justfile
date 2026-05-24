# Justfile for hyperstack.rb — common VM and vLLM operations
# Usage: just <recipe> [args]
# Install: cargo install just

set dotenv-load := false
set shell := ["/bin/bash", "-cu"]

# Path to the Ruby CLI script
ruby := "ruby"
hypr_dir := source_directory()
hypr := ruby + " -I" + hypr_dir + "/lib " + hypr_dir + "/hyperstack.rb"

# Default recipe: show help
[private]
default:
    @just --list --unsorted

# ── VM Lifecycle ─────────────────────────────────────────────────────────

# Create VM1 (defaults to hyperstack-vm1.toml)
create-vm1:
    {{hypr}} --vm 1 create

# Create VM2 (hyperstack-vm2.toml)
create-vm2:
    {{hypr}} --vm 2 create

# Create both VMs concurrently
create-both:
    {{hypr}} --vm both create

# Delete VM1
delete-vm1:
    {{hypr}} --vm 1 delete

# Delete VM2
delete-vm2:
    {{hypr}} --vm 2 delete

# Delete both VMs concurrently
delete-both:
    {{hypr}} --vm both delete

# Recreate VM1 (delete then create, non-interactive)
recreate-vm1: delete-vm1 create-vm1

# Recreate VM2 (delete then create, non-interactive)
recreate-vm2: delete-vm2 create-vm2

# ── Observability ───────────────────────────────────────────────────────

# Watch dashboard: auto-detects active VMs, updates every 5s
watch:
    {{hypr}} watch

# Show status of VM1
status-vm1:
    {{hypr}} --vm 1 status

# Show status of VM2
status-vm2:
    {{hypr}} --vm 2 status

# Show status of all tracked VMs
status-both:
    {{hypr}} --vm both status

# ── Testing ─────────────────────────────────────────────────────────────

# Run inference tests against VM1
test-vm1:
    {{hypr}} --vm 1 test

# Run inference tests against VM2
test-vm2:
    {{hypr}} --vm 2 test

# Run inference tests against all active VMs
test-all:
    {{hypr}} test

# ── Model Management ────────────────────────────────────────────────────

# List available model presets for VM1
model-list-vm1:
    {{hypr}} --vm 1 model list

# List available model presets for VM2
model-list-vm2:
    {{hypr}} --vm 2 model list

# Switch VM1 to a named preset (requires VM to be running)
model-switch-vm1 PRESET:
    {{hypr}} --vm 1 model switch {{PRESET}}

# Switch VM2 to a named preset (requires VM to be running)
model-switch-vm2 PRESET:
    {{hypr}} --vm 2 model switch {{PRESET}}

# ── SSH Access ──────────────────────────────────────────────────────────

# SSH into VM1 (reads public IP from state file)
ssh-vm1:
    @python3 -c "import json, subprocess, os; state = json.load(open(os.path.expanduser('{{hypr_dir}}/.hyperstack-vm1-state.json'))); subprocess.run(['ssh', '-i', '~/.ssh/id_rsa', '-o', 'StrictHostKeyChecking=accept-new', f\"ubuntu@{state['public_ip']}\"])" || echo "VM1 state file not found."

# SSH into VM2 (reads public IP from state file)
ssh-vm2:
    @python3 -c "import json, subprocess, os; state = json.load(open(os.path.expanduser('{{hypr_dir}}/.hyperstack-vm2-state.json'))); subprocess.run(['ssh', '-i', '~/.ssh/id_rsa', '-o', 'StrictHostKeyChecking=accept-new', f\"ubuntu@{state['public_ip']}\"])" || echo "VM2 state file not found."

# ── vLLM Logs ───────────────────────────────────────────────────────────

# Tail vLLM container logs on VM1
logs-vm1:
    @python3 -c "import json, subprocess, os; state = json.load(open(os.path.expanduser('{{hypr_dir}}/.hyperstack-vm1-state.json'))); container = state.get('vllm_container_name', 'vllm_qwen36_27b'); subprocess.run(['ssh', '-i', '~/.ssh/id_rsa', '-o', 'StrictHostKeyChecking=accept-new', f\"ubuntu@{state['public_ip']}\", f'sudo docker logs -f {container}'])" || echo "VM1 state file not found."

# Tail vLLM container logs on VM2
logs-vm2:
    @python3 -c "import json, subprocess, os; state = json.load(open(os.path.expanduser('{{hypr_dir}}/.hyperstack-vm2-state.json'))); container = state.get('vllm_container_name', 'vllm_qwen36_27b'); subprocess.run(['ssh', '-i', '~/.ssh/id_rsa', '-o', 'StrictHostKeyChecking=accept-new', f\"ubuntu@{state['public_ip']}\", f'sudo docker logs -f {container}'])" || echo "VM2 state file not found."

# ── WireGuard ─────────────────────────────────────────────────────────────

# Show local WireGuard tunnel status
wg-status:
    sudo wg show wg1

# Restart local WireGuard tunnel
wg-restart:
    sudo systemctl restart wg-quick@wg1

# ── Git helpers (optional) ────────────────────────────────────────────────

# Show recent commits touching hyperstack files
log:
    git log --oneline -10 -- hyperstack-vm1.toml hyperstack-vm2.toml lib/hyperstack.rb wg1-setup.sh justfile

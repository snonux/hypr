#!/bin/bash
#
# wg1-setup.sh - Set up WireGuard wg1 tunnel between earth and a hyperstack VM
#
# USAGE:
#   ./wg1-setup.sh <VM_PUBLIC_IP> [SERVER_WG_IP] [WG_HOSTNAME]
#
#   VM_PUBLIC_IP  Public IP of the hyperstack VM (required)
#   SERVER_WG_IP  WireGuard IP to assign to this VM's tunnel interface (default: 192.168.3.1)
#                 Use 192.168.3.3 for hyperstack2 when hyperstack1 is already set up.
#   WG_HOSTNAME   Hostname mapped to SERVER_WG_IP in /etc/hosts (default: <vmhostname>.wg1)
#
# EXAMPLES:
#   ./wg1-setup.sh 185.216.20.163                            # VM1 (hyperstack1, 192.168.3.1)
#   ./wg1-setup.sh 185.216.20.200 192.168.3.3 hyperstack2.wg1  # VM2 added to existing tunnel
#
# NETWORK DESIGN:
#   Subnet: 192.168.3.0/24 (separate from wg0's 192.168.2.0/24)
#   Port: 56710/udp
#
#   +----------------+                      +------------------+
#   | earth (client) |                      | hyperstack1 (VM) |
#   | 192.168.3.2    |<--- WireGuard --->   | 192.168.3.1      |
#   +----------------+     tunnel           +------------------+
#        |                                  | vLLM  :11434     |
#        |                                  +------------------+
#        |                                  +------------------+
#        +--------- WireGuard ---------->   | hyperstack2 (VM) |
#                                           | 192.168.3.3      |
#                                           +------------------+
#                                           | vLLM  :11434     |
#                                           +------------------+
#
# WHAT THIS SCRIPT DOES:
#
#   For the FIRST VM (SERVER_WG_IP = 192.168.3.1, default):
#     Generates fresh key-pairs and REPLACES /etc/wireguard/wg1.conf on earth with
#     a single-peer config pointing to this VM.
#
#   For ADDITIONAL VMs (any other SERVER_WG_IP, e.g. 192.168.3.3):
#     Generates new server-side keys and ADDS or UPDATES just the new [Peer] block
#     in the existing /etc/wireguard/wg1.conf, preserving the [Interface] section
#     (client key-pair) and any other peers already present.
#     The existing client public key from wg1.conf is extracted and used in the new
#     VM's server config so it can encrypt traffic to earth.
#
#   On every hyperstack VM (via SSH):
#     - Installs WireGuard if not present
#     - Creates /etc/wireguard/wg1.conf with SERVER_WG_IP as the tunnel address
#     - Opens UFW ports: 56710/udp (WireGuard), 11434/tcp from 192.168.3.0/24
#     - Starts wg-quick@wg1
#
#   On earth (locally):
#     - Installs WireGuard if not present (dnf)
#     - Creates or updates /etc/wireguard/wg1.conf (see above)
#     - Adds SERVER_WG_IP <-> WG_HOSTNAME mapping to /etc/hosts
#     - Restarts wg-quick@wg1
#
# PREREQUISITES:
#   - SSH access to ubuntu@<VM_IP> with key-based auth
#   - UDP port 56710 open in cloud provider's firewall/security group
#
# RE-RUNNING:
#   When a VM IP changes, simply re-run this script with the new IP.
#   It will regenerate keys and update configs on both sides.
#

set -euo pipefail

# Fixed network constants that must match hyperstack-vm*.toml [network] section.
WG_INTERFACE="wg1"
WG_PORT="56710"
DEFAULT_SERVER_WG_IP="192.168.3.1"
CLIENT_WG_IP="192.168.3.2"
SUBNET_MASK="24"
SSH_USER="ubuntu"
SSH_PORT="${HYPERSTACK_SSH_PORT:-22}"
SSH_CONNECT_TIMEOUT="${HYPERSTACK_SSH_CONNECT_TIMEOUT:-10}"
SSH_KNOWN_HOSTS_PATH="${HYPERSTACK_SSH_KNOWN_HOSTS_PATH:-}"
SSH_PRIVATE_KEY_PATH="${HYPERSTACK_SSH_PRIVATE_KEY_PATH:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_warning() { echo -e "${YELLOW}$1${NC}"; }
print_success() { echo -e "${GREEN}$1${NC}"; }
print_error()   { echo -e "${RED}$1${NC}"; }

# Retry wrapper for SSH/SCP commands that may fail due to transient
# connection resets (e.g. sshd restart from unattended-upgrades).
retry_ssh() {
    local max_attempts=5
    local attempt=1
    local delay=10
    while true; do
        if "$@"; then
            return 0
        fi
        if [[ $attempt -ge $max_attempts ]]; then
            print_error "Command failed after ${max_attempts} attempts: $*"
            return 1
        fi
        echo "  SSH attempt ${attempt}/${max_attempts} failed, retrying in ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay + 5))
    done
}

SSH_BASE_OPTS=(-o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}" -o BatchMode=yes -p "${SSH_PORT}")
SCP_BASE_OPTS=(-o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}" -o BatchMode=yes -P "${SSH_PORT}")
if [[ -n "${SSH_KNOWN_HOSTS_PATH}" ]]; then
    SSH_BASE_OPTS+=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS_PATH}")
    SCP_BASE_OPTS+=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS_PATH}")
fi
if [[ -n "${SSH_PRIVATE_KEY_PATH}" && -f "${SSH_PRIVATE_KEY_PATH}" ]]; then
    SSH_BASE_OPTS+=(-i "${SSH_PRIVATE_KEY_PATH}")
    SCP_BASE_OPTS+=(-i "${SSH_PRIVATE_KEY_PATH}")
fi

ssh_vm() {
    ssh "${SSH_BASE_OPTS[@]}" "${SSH_USER}@${VM_IP}" "$@"
}

scp_vm() {
    scp "${SCP_BASE_OPTS[@]}" "$@"
}

# Updates or adds a [Peer] block in the existing /etc/wireguard/wg1.conf.
# Preserves the [Interface] section and any other peers; only the block for
# SERVER_WG_IP (matched by AllowedIPs) is replaced.
# Uses python3 for safe regex-based TOML-like block manipulation.
update_peer_in_client_config() {
    local server_ip="$1"
    local server_pubkey="$2"
    local vm_ip="$3"
    local tmpfile conf_copy
    tmpfile=$(mktemp)
    conf_copy=$(mktemp)

    # /etc/wireguard/wg1.conf is root-owned; read it via sudo into a user-readable temp copy.
    if ! sudo cat /etc/wireguard/wg1.conf > "$conf_copy" 2>/dev/null; then
        print_error "Cannot read /etc/wireguard/wg1.conf. Run wg1-setup.sh for VM1 (192.168.3.1) first."
        rm -f "$tmpfile" "$conf_copy"
        return 1
    fi

    python3 - "$server_ip" "$server_pubkey" "$vm_ip" "$WG_PORT" "$conf_copy" "$tmpfile" << 'PYEOF'
import sys, re

server_ip, server_pubkey, vm_ip, wg_port, conf_copy, tmpfile = sys.argv[1:]

with open(conf_copy) as f:
    content = f.read()

if not content.strip():
    print("ERROR: wg1.conf is empty. Run wg1-setup.sh for VM1 (192.168.3.1) first.", file=sys.stderr)
    sys.exit(1)

# Split into sections: [Interface] block + any [Peer] blocks.
# Each section starts with a [ header; split on newline-[ boundaries.
parts = re.split(r'(?=\n\[)', content)

# Remove any existing [Peer] block whose AllowedIPs matches server_ip/32.
kept = [p for p in parts if not (re.search(r'^\[Peer\]', p.lstrip()) and f'AllowedIPs = {server_ip}/32' in p)]

new_peer = f"""
[Peer]
# hyperstack VM ({server_ip})
PublicKey = {server_pubkey}
Endpoint = {vm_ip}:{wg_port}
AllowedIPs = {server_ip}/32
PersistentKeepalive = 25"""

result = ''.join(kept).rstrip('\n') + '\n' + new_peer + '\n'

with open(tmpfile, 'w') as f:
    f.write(result)
print('peer-updated-ok')
PYEOF

    local rc=$?
    rm -f "$conf_copy"
    if [[ $rc -eq 0 ]]; then
        sudo cp "${tmpfile}" /etc/wireguard/wg1.conf
        sudo chmod 600 /etc/wireguard/wg1.conf
    fi
    rm -f "${tmpfile}"
    return $rc
}

# Validate arguments
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <VM_PUBLIC_IP> [SERVER_WG_IP] [WG_HOSTNAME]"
    echo "Example (VM1): $0 185.216.20.163"
    echo "Example (VM2): $0 185.216.20.200 192.168.3.3 hyperstack2.wg1"
    exit 1
fi

VM_IP="$1"
SERVER_WG_IP="${2:-${DEFAULT_SERVER_WG_IP}}"
# Default WG_HOSTNAME: replace 192.168.3. prefix with 'hyperstack' and append .wg1,
# or fall back to server IP if the address doesn't match the expected pattern.
WG_HOSTNAME="${3:-$(echo "$SERVER_WG_IP" | sed 's/^192\.168\.3\.\(.*\)/hyperstack\1.wg1/' || echo "${SERVER_WG_IP}.wg1")}"

# Determine mode: first VM replaces the entire client config; additional VMs add a peer.
IS_FIRST_VM=false
[[ "$SERVER_WG_IP" == "$DEFAULT_SERVER_WG_IP" ]] && IS_FIRST_VM=true

echo "=============================================="
print_warning "IMPORTANT: Ensure UDP port ${WG_PORT} is open on the VM!"
print_warning "This must be configured in your cloud provider's"
print_warning "firewall/security group settings."
if [[ "$IS_FIRST_VM" == "false" ]]; then
    print_warning "Mode: ADD PEER — ${SERVER_WG_IP} (${WG_HOSTNAME}) will be added to existing wg1.conf."
    print_warning "Ensure the first VM (192.168.3.1) has already been set up."
fi
echo "=============================================="
echo ""
read -rp "Press Enter to continue (or Ctrl+C to abort)..."
echo ""

# Create temporary directory for key generation
TMPDIR=$(mktemp -d)
trap 'rm -rf $TMPDIR' EXIT

echo "=== Generating WireGuard keys locally ==="

# Generate server (hyperstack VM) keys — always fresh for each VM.
wg genkey > "$TMPDIR/server-privatekey"
wg pubkey < "$TMPDIR/server-privatekey" > "$TMPDIR/server-publickey"
SERVER_PRIVATE_KEY=$(cat "$TMPDIR/server-privatekey")
SERVER_PUBLIC_KEY=$(cat  "$TMPDIR/server-publickey")

if [[ "$IS_FIRST_VM" == "true" ]]; then
    # First VM: generate fresh client keys; the entire wg1.conf will be replaced.
    wg genkey > "$TMPDIR/client-privatekey"
    wg pubkey < "$TMPDIR/client-privatekey" > "$TMPDIR/client-publickey"
    CLIENT_PRIVATE_KEY=$(cat "$TMPDIR/client-privatekey")
    CLIENT_PUBLIC_KEY=$(cat  "$TMPDIR/client-publickey")
    print_success "Keys generated (first VM — full config will be replaced)"
else
    # Additional VM: reuse the existing client keys from /etc/wireguard/wg1.conf so that
    # the first VM's server config (which already stores the client public key) keeps working.
    CLIENT_PRIVATE_KEY=$(sudo cat /etc/wireguard/wg1.conf | grep -m1 'PrivateKey' | awk '{print $3}')
    if [[ -z "$CLIENT_PRIVATE_KEY" ]]; then
        print_error "Cannot extract client private key from /etc/wireguard/wg1.conf."
        print_error "Run this script for VM1 (192.168.3.1) first."
        exit 1
    fi
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
    print_success "Keys generated (additional VM — client keys reused from existing wg1.conf)"
fi

echo ""
echo "=== Creating server (hyperstack VM ${SERVER_WG_IP}) configuration ==="

cat > "$TMPDIR/server-wg1.conf" << EOF
# WireGuard wg1 configuration for hyperstack VM (${SERVER_WG_IP})
# Server side of earth <-> hyperstack tunnel
# Generated by wg1-setup.sh on $(date)

[Interface]
Address = ${SERVER_WG_IP}/${SUBNET_MASK}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}

[Peer]
# earth (client)
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_WG_IP}/32
EOF

print_success "Server config created (server IP: ${SERVER_WG_IP})"

if [[ "$IS_FIRST_VM" == "true" ]]; then
    echo ""
    echo "=== Creating client (earth) configuration ==="

    cat > "$TMPDIR/client-wg1.conf" << EOF
# WireGuard wg1 configuration for earth
# Client side of earth <-> hyperstack tunnel
# Generated by wg1-setup.sh on $(date)

[Interface]
Address = ${CLIENT_WG_IP}/${SUBNET_MASK}
PrivateKey = ${CLIENT_PRIVATE_KEY}

[Peer]
# hyperstack VM (${SERVER_WG_IP})
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${VM_IP}:${WG_PORT}
AllowedIPs = ${SERVER_WG_IP}/32
PersistentKeepalive = 25
EOF

    print_success "Client config created"
fi

echo ""
echo "=== Setting up hyperstack VM (${VM_IP}, tunnel IP ${SERVER_WG_IP}) ==="

echo "Testing SSH connection..."
retry_ssh ssh_vm "echo 'SSH OK'"
print_success "SSH connection OK"

echo "Installing WireGuard on hyperstack..."
retry_ssh ssh_vm "which wg >/dev/null 2>&1 || (sudo apt update && sudo apt install -y wireguard)"
print_success "WireGuard installed"

echo "Copying wg1.conf to hyperstack..."
retry_ssh scp_vm "$TMPDIR/server-wg1.conf" "${SSH_USER}@${VM_IP}:/tmp/wg1.conf"
retry_ssh ssh_vm "sudo mv /tmp/wg1.conf /etc/wireguard/wg1.conf && sudo chmod 600 /etc/wireguard/wg1.conf"
print_success "Server config installed"

echo "Configuring firewall (ufw) on hyperstack..."
retry_ssh ssh_vm bash -s << 'REMOTE_SCRIPT'
sudo ufw allow ssh comment 'Allow SSH' 2>/dev/null || true
sudo ufw --force enable >/dev/null 2>&1 || true
sudo ufw allow 56710/udp comment 'WireGuard wg1' 2>/dev/null || true
sudo ufw allow from 192.168.3.0/24 to any port 11434 proto tcp comment 'Ollama/vLLM via wg1' 2>/dev/null || true
echo "Firewall rules added"
REMOTE_SCRIPT
print_success "Firewall configured"

echo "Configuring Ollama to listen on 0.0.0.0 (if installed)..."
retry_ssh ssh_vm bash -s << 'REMOTE_SCRIPT'
if [ -f /etc/systemd/system/ollama.service.d/override.conf ] && \
   grep -q 'OLLAMA_HOST' /etc/systemd/system/ollama.service.d/override.conf; then
  echo "Ollama override already configured, skipping"
else
  sudo mkdir -p /etc/systemd/system/ollama.service.d
  cat << 'OVERRIDE' | sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
OVERRIDE
  sudo systemctl daemon-reload
  sudo systemctl restart ollama 2>/dev/null || echo "Note: Ollama not running or not installed"
fi
REMOTE_SCRIPT
print_success "Ollama configured"

echo "Starting wg1 on hyperstack..."
retry_ssh ssh_vm "sudo systemctl start wg-quick@wg1 2>/dev/null || sudo wg-quick up wg1"
print_success "wg1 started on hyperstack"

echo ""
echo "=== Setting up earth (local) ==="

if ! which wg >/dev/null 2>&1; then
    echo "Installing WireGuard locally..."
    sudo dnf install -y wireguard-tools
fi
print_success "WireGuard installed locally"

if [[ "$IS_FIRST_VM" == "true" ]]; then
    echo "Installing fresh wg1.conf locally (first VM — replaces any existing config)..."
    sudo cp "$TMPDIR/client-wg1.conf" /etc/wireguard/wg1.conf
    sudo chmod 600 /etc/wireguard/wg1.conf
    print_success "Client config installed"
else
    echo "Adding peer ${SERVER_WG_IP} to existing wg1.conf (additional VM)..."
    update_peer_in_client_config "$SERVER_WG_IP" "$SERVER_PUBLIC_KEY" "$VM_IP"
    print_success "Peer added to client config"
fi

# Update /etc/hosts so that WG_HOSTNAME resolves to the VM's WireGuard IP.
# hyperstack.rb uses this hostname in test URLs and informational output.
echo "Updating /etc/hosts: ${SERVER_WG_IP} ${WG_HOSTNAME}..."
sudo sed -i "/ ${WG_HOSTNAME}$/d" /etc/hosts   # Remove stale entry if present
echo "${SERVER_WG_IP} ${WG_HOSTNAME}" | sudo tee -a /etc/hosts > /dev/null
print_success "/etc/hosts updated"

echo "Restarting wg1 locally..."
sudo systemctl stop  wg-quick@wg1 2>/dev/null || true
sudo systemctl start wg-quick@wg1
print_success "wg1 restarted locally"

echo ""
echo "=============================================="
print_success "Setup complete!"
echo "=============================================="
echo ""
echo "WireGuard wg1 tunnel peer active:"
echo "  hyperstack VM (server): ${SERVER_WG_IP} (${WG_HOSTNAME})"
echo "  earth (client):         ${CLIENT_WG_IP}"
echo ""
echo "=== Verification commands ==="
echo ""
echo "# Check tunnel status:"
echo "sudo wg show wg1"
echo ""
echo "# Ping hyperstack via tunnel:"
echo "ping -c 3 ${SERVER_WG_IP}"
echo ""
echo "# Verify default route is UNCHANGED:"
echo "ip route | grep default"
echo ""
echo "# Test vLLM access:"
echo "curl http://${WG_HOSTNAME}:11434/v1/models"
echo ""
echo "=== Manual start/stop commands ==="
echo ""
echo "# Stop tunnel:"
echo "sudo systemctl stop wg-quick@wg1"
echo ""
echo "# Start tunnel:"
echo "sudo systemctl start wg-quick@wg1"
echo ""
echo "# Restart on hyperstack (if VM rebooted):"
echo "ssh ${SSH_USER}@${VM_IP} 'sudo systemctl start wg-quick@wg1'"

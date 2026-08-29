# WireGuard troubleshooting

## Tunnel issues on first VM start

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

## Firewall rules (Hyperstack security group)

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

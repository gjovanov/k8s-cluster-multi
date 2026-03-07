# Host Reboot Recovery

How the K8s cluster auto-recovers after a bare-metal host reboot.

## Boot Sequence

After a host (mars, zeus, or jupiter) reboots, the following happens automatically:

1. **WireGuard** (`wg-quick@wg0.service`) starts and runs `wg-postup.sh`
2. **libvirtd** starts, re-creates its iptables chains (`LIBVIRT_FWI/FWO/FWX/PRT`)
3. **libvirt-guests** — configured with `ON_BOOT=ignore` so VMs are NOT restored from managed save (which causes the "paused" state bug)
4. **VMs auto-start** via `virsh autostart` — libvirtd starts them fresh
5. **wg-fix-iptables.service** runs after both libvirtd and wg-quick, re-applying the WireGuard iptables rules to ensure they are above libvirt's chains

## The Libvirt iptables Race Condition

Libvirt inserts its own iptables chains on startup:
- `LIBVIRT_FWI` — rejects incoming traffic to VM subnet unless RELATED/ESTABLISHED
- `LIBVIRT_FWO` — rejects outgoing traffic from VM subnet
- `LIBVIRT_PRT` — masquerades (NATs) VM subnet traffic

WireGuard's PostUp script inserts ACCEPT rules in the FORWARD chain and anti-masquerade RETURN rules in POSTROUTING. However, if libvirt starts **after** WireGuard, it pushes its chains above the WireGuard rules, breaking cross-host VM traffic.

### Fix: `wg-fix-iptables.service`

A systemd oneshot service that:
- Runs **after** `libvirtd.service`, `libvirt-guests.service`, and `wg-quick@wg0.service`
- Waits 5 seconds for libvirt to fully initialize
- Re-runs `wg-postup.sh` (which is idempotent — deletes existing rules before inserting)

This ensures the correct iptables order:

```
FORWARD chain:
  1. ACCEPT  virbr1 → wg0     ← WireGuard (cross-host VM traffic)
  2. ACCEPT  wg0 → virbr1     ← WireGuard (cross-host VM traffic)
  3. LIBVIRT_FWX                ← libvirt
  4. LIBVIRT_FWI                ← libvirt
  5. LIBVIRT_FWO                ← libvirt

nat POSTROUTING chain:
  1. RETURN  10.10.X.0/24 → 10.10.Y.0/24  ← anti-masquerade
  2. RETURN  10.10.Y.0/24 → 10.10.X.0/24  ← anti-masquerade
  ...
  N. LIBVIRT_PRT                            ← libvirt (MASQUERADE)
```

## The "Paused" VM Bug

By default, `libvirt-guests.service` uses `ON_SHUTDOWN=suspend` which saves VM state to disk (`virsh managedsave`). On next boot with `ON_BOOT=start`, it restores from the saved state, which can leave VMs in a `paused` state.

### Fix: `/etc/default/libvirt-guests`

```
ON_BOOT=ignore       # Don't restore from managed save; let autostart handle it
ON_SHUTDOWN=shutdown  # Clean shutdown instead of suspend/managedsave
```

Combined with `virsh autostart` on each VM, this ensures VMs start fresh after host reboot.

## Configuration Files

| File | Location | Purpose |
|------|----------|---------|
| `wg-postup.sh` | `/usr/local/bin/wg-postup.sh` | Idempotent iptables rules for WireGuard |
| `wg-fix-iptables.service` | `/etc/systemd/system/wg-fix-iptables.service` | Re-apply iptables after libvirt |
| `libvirt-guests` | `/etc/default/libvirt-guests` | `ON_BOOT=ignore`, `ON_SHUTDOWN=shutdown` |

## Manual Recovery

If a host reboots and the cluster doesn't recover automatically:

```bash
# 1. Check VMs
sudo virsh list --all

# 2. If VMs are paused, resume them
sudo virsh resume <vm-name>

# 3. If VMs are shut off, start them
sudo virsh start <vm-name>

# 4. Fix iptables if needed
sudo /usr/local/bin/wg-postup.sh

# 5. Verify iptables order
sudo iptables -L FORWARD -n --line-numbers
sudo iptables -t nat -L POSTROUTING -n --line-numbers

# 6. Restart kubelet on VMs if needed
ssh ubuntu@<vm-ip> "sudo systemctl restart kubelet"

# 7. Restart HAProxy on mars (if mars was rebooted)
sudo systemctl restart haproxy
```

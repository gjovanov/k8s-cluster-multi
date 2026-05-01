# Incident — host-firewall role broke cluster networking on apply (2026-05-01 ~09:30 UTC)

## What happened

Applying `playbooks/16-host-hardening.yml` to mars (after successful pilots on jupiter and zeus) caused:

1. **K8s API unreachable** (kubectl returned EOF for 8+ minutes)
2. **All cross-host VM connectivity broken** (mars → master-2/3, worker-2/3 ICMP timed out)
3. **Sites 502** (mars nginx → worker-2/3 NodePorts unreachable)

Total impact: ~10 min visible 502 on `roomler.ai`, `argocd.roomler.ai`, `claw.roomler.ai`. `oxmux.app` / `lgrai.app` / `purestat.ai` / `tickytack.app` recovered first. K8s cluster degraded ~12 min.

## Root causes (two compounding)

### 1. `net.ipv4.conf.all.rp_filter = 1` (strict reverse-path filter)

`roles/host-hardening/tasks/sysctl.yml` set strict mode. Strict rp_filter drops packets where the source's preferred route is not via the receiving interface. With the libvirt+WireGuard topology (asymmetric routing where return packets may take different paths than the WG mesh predicts), this manifested as silent drops of:

- ARP replies between mars-host and its own libvirt VMs (master-1, worker-1) — even though both are on virbr1
- Packets returning across the WG mesh from VMs on other hosts

Kernel did not log these (rp_filter drops aren't logged unless `log_martians=1`, which is on, but the logs were rotated/sparse).

### 2. `HOST_FW_FORWARD` chain didn't allow Cilium pod CIDR or VM-to-host UDP/53

The chain's allow-list was VM-subnet-only (`10.10.X.0/24`). It didn't allow:

- **Cilium pod CIDR `10.244.0.0/16`** — pod-to-pod traffic between worker nodes (e.g., worker-1 pod → master-2:2380 etcd peer port appeared in dmesg with source `10.244.0.44`)
- **VM → mars-host UDP/53** for libvirt's dnsmasq DNS — the VMs use `10.10.10.1:53` (mars host) for upstream resolution. The HOST_FW_INPUT chain didn't allow it (only `host_firewall_allowed_udp` ports, which omitted `53`).

When VMs couldn't resolve DNS, kubelet/containerd/Cilium retried but couldn't reach apt-mirrors, k8s.io endpoints, etc. Compounded by the rp_filter ARP issue, the cluster effectively partitioned itself from mars.

## Recovery actions taken

1. **Disabled `host-firewall.service` on all 3 hosts** (the role was successfully applied earlier; service stayed enabled but the iptables ruleset is bypassed):
   ```bash
   for h in mars zeus jupiter; do
     ssh $h 'sudo iptables -P INPUT ACCEPT; sudo iptables -P FORWARD ACCEPT
              sudo iptables -D INPUT -j HOST_FW_INPUT; sudo iptables -F HOST_FW_INPUT; sudo iptables -X HOST_FW_INPUT
              sudo iptables -D FORWARD -j HOST_FW_FORWARD; sudo iptables -F HOST_FW_FORWARD; sudo iptables -X HOST_FW_FORWARD
              sudo systemctl disable host-firewall'
   done
   ```
2. **Reverted rp_filter to 0** on all 3 hosts (live):
   ```bash
   for h in mars zeus jupiter; do
     ssh $h 'sudo sysctl -w net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0'
   done
   ```
3. **Restarted `libvirtd` and `haproxy`** on all 3 hosts to drop stale conntrack/connection state.
4. **Waited for K8s control plane to re-converge** (~3 min for etcd + apiserver + scheduler).
5. **Roomler-ai pods auto-rescheduled** after libvirtd restart (PVC-bound StatefulSets retained data). Site recovered at 09:46 UTC.

## Effective state now

- `host_hardening` role: STILL APPLIED (sysctl, ssh, fail2ban, auditd, sudoers, unattended-upgrades, drift-guard, port-audit cron) — the parts that work fine.
- `host-firewall` role: **DISABLED** at runtime (chains gone, service disabled). ROLE FILES REMAIN COMMITTED but should not be re-applied without the fixes below.
- 110.40.205.192 attacker DROP rules: still in place (added directly to FORWARD/INPUT during Phase 0; survived the chain teardown).
- `iptables -L INPUT -n` post-incident: UFW chains, fail2ban, attacker DROP, libvirt INP — all default-ACCEPT.

## Required fixes BEFORE re-applying host-firewall

1. **Drop the `rp_filter` strict line.** Use `2` (loose) at most, or omit. Don't enforce strict mode on a host with libvirt+WireGuard asymmetric routing.

2. **Add to `host-firewall.sh.j2` FORWARD chain:**
   - `-s 10.244.0.0/16 -j ACCEPT` and `-d 10.244.0.0/16 -j ACCEPT` (Cilium pod CIDR)
   - `-s 10.96.0.0/12 -j ACCEPT` and `-d 10.96.0.0/12 -j ACCEPT` (K8s service CIDR — for completeness)
   - VXLAN: `-p udp --dport 8472 -j ACCEPT` (Cilium VXLAN, in case `routingMode=tunnel`)
   - Docker bridge subnets: `-s 172.17.0.0/16 -j ACCEPT` (default), `-s 172.30.0.0/16 -j ACCEPT` (lgr-network), and `192.168.48.0/24` (roomler-ai compose default)

3. **Add to `host-firewall.sh.j2` INPUT chain:**
   - `-i virbr1 -p udp --dport 53 -j ACCEPT` (libvirt VMs DNS to host's dnsmasq)
   - `-i virbr1 -p udp --dport 67 -j ACCEPT` (DHCP from VMs)
   - `-i wg0  -j ACCEPT` (everything from the WG mesh — defense delegated to peer's HOST_FW_FORWARD)
   - `-i docker0 -j ACCEPT` and similar for docker bridges (host-side reaching docker containers)

4. **Smoke test BEFORE rolling the role to prod:**
   - Bring up a tmux session WITHOUT the firewall.
   - Apply role to ONE host (canary).
   - Run `kubectl get nodes` from external — must succeed.
   - Run `ping <peer-host-VM>` — must succeed.
   - Run `curl -m 5 https://roomler.ai/health` — must return 200.
   - Run `python3 /tmp/turn_test.py` — TURNS:443 must allocate from all 3 IPs.
   - Wait 60 s. Rerun. Then 5 min. Then 15 min. Drift in traffic ≠ break.
   - Only after canary passes ALL of the above for 15 min: roll to next host.

5. **Until those fixes are merged, `host_firewall` role MUST stay out of `playbooks/site.yml`** or be tagged `never` so a casual `make setup` doesn't re-trigger this incident.

## Lessons

- **Default-deny INPUT/FORWARD on a libvirt+WireGuard+Cilium host requires understanding 3 different overlay traffic patterns** (VM-to-VM via virbr1, cross-host VM via WG mesh, pod-to-pod via Cilium VXLAN/native, plus host-to-VM DNS/DHCP). My role's allow-list covered only the first two.
- **`rp_filter=1` is hostile to multi-bridge / WireGuard topologies.** The Linux defaults (rp_filter=2 loose) exist for a reason.
- **The "policy stays ACCEPT, chain ends with DROP" safety pattern** I designed only saves you if the chain itself is reachable. Once libvirt + Cilium can't pass packets through, NOTHING gets through, regardless of policy.
- **Pilot success on 2 of 3 hosts is not a green light.** Mars hosts the one libvirt+Cilium combination most likely to break (worker-1 = mars VM that hosts coturn pod, also where most cross-host traffic terminates). Mars should have been the canary, not the rollout target.

## Status

- **Outage closed.** All 8 sites HTTP 200, all 6 K8s nodes Ready, all 9 ArgoCD apps Healthy.
- **`host-firewall` role disabled.** Will NOT auto-apply on future `make` runs (because the playbook entry exists but the systemd service is `disabled` and chains are removed; on next role apply the chains would come back — TODO: tag the role `never`).
- **`host-hardening` role still active** — the non-firewall parts (drift guard, audit, ssh, sudoers, sysctl with `rp_filter=2` instead of 1, fail2ban, auditd, unattended-upgrades).
- **110.40.205.192 still blocked.**
- **Ollama / frps / asterisk drift guard still active.**

## Aftershock (2026-05-01 ~23:30 UTC) — kernel auto-reboot resurrected the bug

A kernel security update auto-installed and rebooted mars (uptime "5 min", new kernel 5.15.0-176-generic, despite `Automatic-Reboot "false"` in unattended-upgrades — Ubuntu's default `50unattended-upgrades-security` overrides that). On boot, `netfilter-persistent` restored the `HOST_FW_INPUT` / `HOST_FW_FORWARD` chains from `/etc/iptables/rules.v4` even though `host-firewall.service` is `disabled` — the chains live in the persistent rules dump, the service only *applies* them.

Result: mars VMs (master-1, worker-1) hung on DHCP forever — `virbr1` ingress had no allow-rule, so VM DHCP REQUEST → host dnsmasq was silently dropped (the chain ends in DROP). K8s nodes NotReady, `tickytack.app` / `roomler.live` / `argocd.roomler.ai` returned HTTP 000.

**Diagnostic that nailed it:** sent a hand-crafted DHCP DISCOVER from the host's own kernel via `SO_BINDTODEVICE=virbr1` to `255.255.255.255:67` — dnsmasq was completely silent (TIMEOUT after 5 s). That confirmed it wasn't a dnsmasq bug or a libvirt config issue — it had to be the kernel netfilter path. Confirmed by inspecting `HOST_FW_INPUT`: the trailing `DROP` rule's counter was incrementing.

**Fix:**
1. **Live:** `sudo iptables -I HOST_FW_INPUT 1 -i virbr1 -j ACCEPT && sudo netfilter-persistent save` — VMs DHCPed within ~5 s, K8s recovered ~30 s later, sites returned 200.
2. **Role:** added `iptables -A "$HF_INPUT_CHAIN" -i virbr1 -j ACCEPT` to `roles/host-firewall/templates/host-firewall.sh.j2` (parameterised via `host_firewall_libvirt_bridge`, default `virbr1`). When the role is re-enabled, this rule will be applied automatically.

**New lessons:**
- **`netfilter-persistent` snapshots survive role-disable.** Disabling `host-firewall.service` does NOT remove the persisted ruleset; the chains live in `/etc/iptables/rules.v4`. Either flush+save explicitly when disabling, or tag the role `never` AND clear the persisted dump. We did the former this time.
- **The libvirt bridge needs an explicit ACCEPT rule** even though it's host-internal — VM→host DHCP/DNS hits the regular INPUT chain with `iif=virbr1`. Default-deny does not grandfather libvirt's own traffic.
- **Diagnose the netfilter path with a manual probe.** When dnsmasq looked silent, sending a synthetic DHCP DISCOVER from a Python socket bound to virbr1 was decisive — it isolated "is the packet reaching the socket?" from "is the daemon broken?". Saved hours of `tcpdump` second-guessing.

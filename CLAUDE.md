# CLAUDE.md — k8s-cluster-multi

Operational guidance for Claude Code working in this repo. Read this FIRST.

## You are running ON mars

Inventory uses `ansible_connection: local` for `mars` — when this repo is invoked, the cwd is on mars itself (the bare-metal control node hosting `master-1` + `worker-1`). `kubectl`, `virsh`, `iptables`, `docker`, `ssh` to other hosts all run from here.

- mars public IPs: `94.130.141.98` (primary) + `94.130.141.74` (alias)
- zeus  public IP: `5.9.157.226` (host SSH user `gjovanov`)
- jupiter public IP: `5.9.157.221` (host SSH user `gjovanov`)
- WireGuard mesh: `10.10.0.0/24` endpoints, peer subnets `10.10.10.0/24` (mars), `10.10.20.0/24` (zeus), `10.10.30.0/24` (jupiter)
- VM SSH: `ssh -i files/ssh/<host>/k8s_ed25519 ubuntu@10.10.<X>.{10,11}` (zeus/jupiter need `-o ProxyJump=gjovanov@<host-public-ip>`)

## Cluster topology

| Host | Bare-metal | Master VM | Worker VM |
|------|-----------|-----------|-----------|
| mars | 94.130.141.98 | k8s-master-1 (10.10.10.10) | k8s-worker-1 (10.10.10.11) |
| zeus | 5.9.157.226 | k8s-master-2 (10.10.20.10) | k8s-worker-2 (10.10.20.11) |
| jupiter | 5.9.157.221 | k8s-master-3 (10.10.30.10) | k8s-worker-3 (10.10.30.11) |

Mars is the front-of-house: hosts the docker `nginx` container that fronts every public site (roomler.ai, lgrai.app, oxmux.app, argocd.roomler.ai, registry.roomler.ai, tickytack.app, roomler.live, purestat.ai, etc.) and the registry/argocd reverse proxies. Zeus + jupiter are pure compute.

## CRITICAL: host-firewall is a known foot-gun

`roles/host-firewall/` enforces default-deny on `HOST_FW_INPUT` / `HOST_FW_FORWARD` chains hooked into INPUT/FORWARD. The 2026-05-01 rollout broke the cluster twice (`docs/mars-firewall-incident.md`). Current state:

1. **Play is tagged `never`** in `playbooks/16-host-hardening.yml` — does NOT auto-apply with `make` or `playbooks/site.yml`. Only opt-in via `--tags=host-firewall`.
2. **Persisted ruleset still active.** `/etc/iptables/rules.v4` was saved when chains were live and `netfilter-persistent` reloads them at every boot — even though the service is disabled. Disabling the service is **not** equivalent to flushing the chains.
3. **Required INPUT allow-rules** (now in template, but verify on any newly-rebuilt host):
   - `-i lo`
   - `-m conntrack --ctstate ESTABLISHED,RELATED`
   - `-i virbr1` ← **must be present or VMs hang on DHCP forever**
   - `-i wg0` style rules for WireGuard (`udp/51820`, then peer-traffic ESTABLISHED via conntrack)
   - per-host TCP/UDP allow-list from `inventory/host_vars/<host>.yml`
4. **rp_filter MUST be 2 (loose).** `roles/host-hardening/tasks/sysctl.yml` is correct. rp_filter=1 (strict) silently drops ARP replies in the libvirt+WireGuard asymmetric-routing topology.
5. **Drift guard is fine** — `roles/host-hardening/` (the non-firewall part) auto-applies in `playbooks/16-host-hardening.yml`. It runs `assert_no_banned.yml` (ollama/frps/asterisk/etc.) and the daily `listening-ports-audit.sh`.

## When networking breaks on mars

Symptom: K8s nodes NotReady, `kubectl` hangs, `tickytack.app`/`argocd.roomler.ai`/`roomler.live` return HTTP 000. The VMs are listed `running` by `virsh` but not pingable on `10.10.10.{10,11}`.

Recovery checklist (`docs/mars-firewall-incident.md` has the full playbook):

1. `sudo iptables -L HOST_FW_INPUT -nv | tail -3` — if last rule is `DROP` and counter is non-zero, that's the bug.
2. `sudo iptables -I HOST_FW_INPUT 1 -i virbr1 -j ACCEPT && sudo netfilter-persistent save`
3. `sudo virsh destroy k8s-master-1; sudo virsh start k8s-master-1` (same for worker-1) if VMs are wedged in stale-DHCP state.
4. `sudo timeout 8 tcpdump -ni virbr1 'port 67 or arp'` — confirm DHCP REQUEST → OFFER cycle.
5. `KUBECONFIG=/home/gjovanov/.kube/config kubectl get nodes` — should show all 6 Ready within 30 s.

Diagnostic that nailed the 2026-05-01 outage: synthetic DHCP DISCOVER from a Python socket bound to virbr1 (`SO_BINDTODEVICE`) — if dnsmasq is silent for 5 s, the packet is being dropped before it reaches userspace. That isolates "iptables" from "dnsmasq config" instantly.

## Key references

- `docs/security-audit-2026-04-30.md` — Ollama incident post-mortem (public; sensitive creds redacted to `<redacted>`)
- `docs/mars-firewall-incident.md` — host-firewall rollout outage + virbr1 aftershock
- `docs/host-reboot-recovery.md` — what's expected to auto-recover on host reboot
- `files/suspicious-sweep.sh` — ad-hoc audit script for all 9 nodes (banned-keyword scan)
- `~/.claude/skills/security-audit/SKILL.md` — incident-response skill (7 phases)

## Commit etiquette

This repo is **public** (`github.com/gjovanov/k8s-cluster-multi`). When committing:

- No real public IPs in code (Makefile uses `198.51.100.x` placeholders, real IPs in `.env`)
- No private keys (`files/ssh/*/k8s_ed25519` is `.gitignore`'d; bootstrap key is `id_ed25519` and IS committed since hosts already converted)
- `files/sealed-secrets.pub.pem` is a public cert — safe
- Redact concrete passwords/tokens to `<redacted>` in post-mortems even if the service is gone

Existing commit-message style: `fix(role): ...`, `chore(k8s): ...`, `sec(audit): ...`, `docs(security): ...`. Keep subject ≤72 chars; body explains *why*. Co-author footer is fine.

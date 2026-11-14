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
4. **rp_filter MUST be 2 (loose).** `roles/host-hardening/tasks/sysctl.yml` is correct. rp_filter=1 (strict) silently drops ARP replies in the libvirt+WireGuard asymmetric-routing topology. The role's file is what a boot applies; the running value is a question of its own (`cat /proc/sys/net/ipv4/conf/all/rp_filter`). The provider's image ships `99-hetzner.conf` with `1`, applied just before `99-host-hardening.conf`, so that file has to be on the host and say `2`: `ansible-playbook playbooks/16-host-hardening.yml --tags sysctl --check --diff` shows whether it does.
5. **Drift guard is fine** — `roles/host-hardening/` (the non-firewall part) auto-applies in `playbooks/16-host-hardening.yml`. It runs `assert_no_banned.yml` (ollama/frps/asterisk/etc.) and the port audit (see "The port audit" below).

## A published container port is NOT behind the host firewall

`-p 8080:80` on a container publishes to every interface, whatever `host_firewall_allowed_tcp` says: the port is rewritten to the container's address on arrival and FORWARDED, so `HOST_FW_INPUT` is never asked, and Docker's own FORWARD rules accept it ahead of `HOST_FW_FORWARD`. Whether such a port is public is decided by `roles/published-port-guard` (phase 18, `make published-port-guard`, opt-in, mars): **closed to the public interface unless the host's inventory lists it** in `published_port_guard_open_tcp` / `_udp`.

- It is a table of its own (`inet published_port_guard`, `/etc/published-port-guard.nft`, loaded by `published-port-guard.service` before Docker). It is not iptables', so `netfilter-persistent`, a re-render of the host firewall and Docker's own rule changes do not touch it. `sudo nft list table inet published_port_guard` shows it and what it dropped.
- A published port also has a listener of its own on the host (`docker-proxy`), which is the path IPv6 takes. That path IS covered by the host's INPUT rules; the ports in `published_port_guard_host_tcp` are closed there as well, so one stale allow rule does not open a container. Keep that list in step with `docker ps`.
- Publish on `127.0.0.1` (`-p 127.0.0.1:8080:80`) whenever only the host needs the port. The guard is for the day somebody forgets.
- Two more tables on mars that are not this repo's and not iptables': `inet ssh_guard`, and `inet lgr_ci_guard` (the lgr CI runner containers on their own Docker network `lgr-ci`; recipe in `gjovanov/lgr`, `infra/ci-runner`). `nft flush ruleset` removes all of them **and** every iptables rule: never run it on a host.

## The port audit

Every ten minutes each bare-metal host compares what listens on it with its lists in `inventory/host_vars/<host>.yml` (`roles/host-hardening`, tag `audit`), and the host's own collector serves the result to the cluster's Prometheus.

- **A listener that is not on the list** and can be reached from another machine fires `UnexpectedListenerOnNode` (critical, mail) once two runs in a row have seen it and five more minutes have passed: 15 to 25 minutes after it appeared. One that came and went between two runs fires nothing, and one bound to loopback only is recorded (`scope="loopback"`), never mailed.
- **To allow a listener**, add its port or a `"low:high"` range to `host_hardening_expected_tcp` / `_udp`. Write `"port@process"` (`"5353@roomlerd"`) when the port is expected from one program only: the entry then covers it while that process holds it, and the same port under any other process is still reported. The name is the `process` label the alert shows. A daemon that also sends from a random port (a resolver, NAT traversal) goes into `host_hardening_expected_udp_ephemeral` by process name: that covers its sockets inside the kernel's ephemeral range and nothing else. Then `ansible-playbook playbooks/16-host-hardening.yml --tags audit --limit <host>`.
- **The collector** is `prometheus-node-exporter` with every default collector off, on the host's tunnel address only (`host_metrics_port`). The scrape is the `ScrapeConfig` `bare-metal-hosts` (`roles/monitoring/templates/bare-metal-hosts-scrape.yml.j2`). A host whose input chain drops by default needs the one rule `host-firewall.sh.j2` carries for the scrape; that play is not run (see above), so the rule is added by hand, as the template has it, and saved.
- **If it goes quiet**: `HostPortAuditNotReporting` fires when a collector answers without a fresh result, and a collector that does not answer is the stack's `TargetDown`. On the host, `sudo /usr/local/bin/listening-ports-audit.sh` prints the two counts and `/var/lib/node_exporter/textfile_collector/host_unexpected_listener.prom` holds the lines.
- The script's rules are pinned by `bash roles/host-hardening/tests/listening-ports-audit.test.sh` (fixtures; no root, no real sockets).
- Rules and scrape objects that changed after the monitoring chart was installed were applied with `kubectl`. A run of phase 13 renders all of them again from `roles/monitoring/templates/`, so keep those templates equal to what is live.

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

## Registry retention (registry.roomler.ai)

`roles/registry-retention` (phase 17, `make registry-retention`, opt-in) installs a weekly job on mars that keeps `latest` + the newest tag of every repo and garbage-collects the rest. Retention is per repo and knows nothing about who deploys what — coturn's DERP sidecar lives in the `roomler-ai` app repo. So the script never deletes an image the cluster references (any pod or workload template, by tag or digest), and **skips the garbage-collect while any referenced image is missing**: until a GC runs, a deleted image's layers are still on disk, and the tag comes back byte-identical by re-pushing its manifest from a node that has it cached (`sudo ctr -n k8s.io content get <manifest digest>` on the worker → `PUT /v2/<repo>/manifests/<tag>`). That is how `lgr-qa`'s image and coturn's DERP image were restored on 2026-09-25/26, after the 2026-09-20 run had deleted both from under running pods. Preview a run with `DRY_RUN=1 ~/.local/bin/registry-retention.sh 1`.

## Commit etiquette

This repo is **public** (`github.com/gjovanov/k8s-cluster-multi`). When committing:

- No real public IPs in code (Makefile uses `198.51.100.x` placeholders, real IPs in `.env`)
- No private keys (`files/ssh/*/k8s_ed25519` is `.gitignore`'d; bootstrap key is `id_ed25519` and IS committed since hosts already converted)
- `files/sealed-secrets.pub.pem` is a public cert — safe
- Redact concrete passwords/tokens to `<redacted>` in post-mortems even if the service is gone

Existing commit-message style: `fix(role): ...`, `chore(k8s): ...`, `sec(audit): ...`, `docs(security): ...`. Keep subject ≤72 chars; body explains *why*. Co-author footer is fine.

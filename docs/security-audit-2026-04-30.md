# Post-mortem — unauthorized Ollama LLM access on `k8s-worker-2`

**Date discovered:** 2026-04-30 ~17:50 UTC
**Severity:** HIGH (unauthenticated remote access to compute and ~46 GB of model weights; potential lateral-movement vector)
**Status:** contained 2026-04-30 ~20:13 UTC

## Timeline

| When | Event |
|---|---|
| 2026-02-27 02:30 | `ollama` binary installed at `/usr/local/bin/ollama` (40 MB) on `k8s-worker-2` VM (zeus host) |
| 2026-02-28 18:54 | Systemd unit `/etc/systemd/system/ollama.service` created |
| 2026-03-07 20:15 UTC | Ollama service first started; runs continuously since |
| ~7 months | Service accumulated three pinned models (qwen2.5vl 7B + 32B, qwen2.5 7B, glm-4.7-flash, t-overflow) totalling 48 GB; `OLLAMA_HOST=0.0.0.0`, `OLLAMA_KEEP_ALIVE=-1` |
| 2026-04-30 ~17:50 UTC | NodeHighCPU alert investigation surfaced ESTABLISHED connection from `110.40.205.192:54506` (China Telecom AS4837) to `10.10.20.11:11434` |
| 2026-04-30 19:55 UTC | Plan approved: remove + harden |
| 2026-04-30 20:11 UTC | Phase 0: blocked `110.40.205.192` on mars/zeus/jupiter INPUT+FORWARD chains; conntrack flushed where available |
| 2026-04-30 20:13 UTC | Phase 0: forensic snapshots taken into `/home/gjovanov/.security-audit/2026-04-30/` |
| 2026-04-30 20:18 UTC | Phase 2: Ollama service stopped, disabled, removed; binary, models, libraries, user account purged. Disk recovered: ~52 GB |

## What was exposed

`/usr/share/ollama/.ollama/models/blobs/` — five LLM models (~46 GB unique blobs):
- qwen2.5vl:32b (21 GB) — multimodal
- qwen2.5vl:7b (6.0 GB) — multimodal
- qwen2.5:7b (4.7 GB)
- glm-4.7-flash (19 GB)
- t-overflow / t-ovf (1.4 KB — Modelfile only, no weights)

API on `*:11434` was unauthenticated. An external client could:
- Run inference against any loaded model (compute theft, data extraction via prompts).
- Pull / push models (`POST /api/pull`, `POST /api/push`).
- Read `/api/tags`, `/api/show` to enumerate the host's model inventory.

No evidence of LATERAL movement: Ollama runs as user `ollama` (UID-allocated), no sudo/setuid, models stored in `/usr/share/ollama/`, no shared filesystem with other namespaces. The K8s control plane was unaffected.

## Root cause

Three contributing factors, none alone sufficient:

1. **Ollama installed outside of configuration management** (manually, via `curl https://ollama.com/install.sh | sh`). Not declared in the cluster's Ansible repo (`k8s-cluster-multi`). No drift-detection or audit captured its presence in the seven months since installation.
2. **Default Ollama bind address is `0.0.0.0`**. The systemd override at `/etc/systemd/system/ollama.service.d/override.conf` even reinforced it: `Environment="OLLAMA_HOST=0.0.0.0"`. No authentication on the API.
3. **Network exposure path** — exact mechanism not fully traced. Audit ruled out:
   - K8s NodePort / LoadBalancer (no `:11434` service in any namespace)
   - mars / zeus / jupiter PREROUTING DNAT (no rule for `:11434`)
   - libvirt static port-forwards (`virsh net-dumpxml k8s-net` shows only generic SNAT range)
   - reverse SSH tunnel (no `ssh -R` processes; `sshd_config` defaults to `AllowTcpForwarding yes` but no current sessions match)
   - frps client (`frpc` not installed on any host or VM; frps dashboard showed 0 active proxies at audit time)

   What's certain: Zeus has `iptables INPUT policy ACCEPT` and `FORWARD policy ACCEPT` with a wide-open `-A FORWARD -d 10.10.20.0/24 -j ACCEPT` rule. There are no per-port restrictions. ANY external IP that finds itself with a route to 10.10.20.11 (e.g., via ICMP redirect, a previously-existing connection's conntrack entry, or via something we haven't identified) will be forwarded to the VM with no firewall in the way. The default-accept posture is the structural enabler.

## Other findings surfaced by the audit (not specifically related to Ollama)

- **Mars `frps.service`** (Fast Reverse Proxy server) running since 2025-09-13. Listens on `0.0.0.0:1500` (frpc connect), `0.0.0.0:1300` (dashboard), `0.0.0.0:1543/1580` (vhost http/https), `0.0.0.0:7000/7001` (kcp/udp). Dashboard credentials are `admin:123654` (factory default). **Severity: HIGH** — anyone with the public URL can take over the proxy server and create arbitrary tunnels into the network. No `frpc` clients currently registered. Recommend: stop+disable, or rotate creds + bind dashboard to `127.0.0.1` and tighten ACL.
- **Mars docker-proxy 0.0.0.0 bindings**: `:27018` (Mongo), `:4001-4070` (lgr-* containers), `:4099` (bun), `:3080`, `:3333`, `:3000` (node), `:2000` (asterisk). Some legitimate, all currently exposed to the internet because UFW ranges allow them. K8s-managed Mongo is reachable internally only — these are **legacy host-Docker** bindings that probably should be restricted to `127.0.0.1`.
- **Mars UFW**: 100+ rules (52 IPv4 + 52 IPv6). Includes overly broad ranges `10000:20000/tcp+udp`, `10200:49200/tcp+udp`, `49160:49200/tcp+udp` — port `11434` falls inside. Also Mongo `27017/27018/27019` exposed, CUPS `631`, asterisk `2000`, redis `6379` indirect via docker-proxy.
- **Zeus & Jupiter**: no UFW (`sudo: ufw: command not found`). `iptables -P INPUT ACCEPT`, `iptables -P FORWARD ACCEPT`, only `LIBVIRT_INP` + `LIBVIRT_FWX/FWI/FWO` + `COTURN_DNAT` chains. Anything bound on a VM and not blocked elsewhere is reachable.
- **Sudoers**: both `gjovanov` and `alazarovski` have `NOPASSWD: ALL` on mars. Compromise of an SSH key would yield instant root.
- **No fail2ban, auditd, AIDE, etckeeper, unattended-upgrades** anywhere in the fleet.
- **Worker-2 VM `rpcbind`** listening on `0.0.0.0:111` — historical NFS-RPC service, not used by anything in the cluster, classic amplification vector.

## Why this wasn't caught earlier

- **No drift detection**: there's no system that periodically compares actual systemd services / listening ports against an expected baseline. A 48 GB binary install in `/usr/local/bin` and a 7-month-running service are invisible to the existing Prometheus alerts.
- **NodeHighCPU was triggered by the LOAD, not the LISTENER**: when Ollama burst to 11 cores during inference, the alert fired. But the alert's scope is "node CPU > 85%", which we now know was misattributed (we initially raised the threshold to 95% on worker-2 thinking the Ollama CPU was *intentional*). The alert should have triggered an audit, not a tuning.
- **No external port-scan automation**: `nmap` against the cluster's public IPs from outside the network would have shown `11434/tcp open` if the path was indeed exposed via mars's broad UFW range. A weekly external scan with a pinned expected-open-ports allow-list would have caught this.

## Closeout actions

| Action | Phase | Owner | Status |
|---|---|---|---|
| Block `110.40.205.192` at INPUT+FORWARD on all 3 hosts | 0 | infra | ✓ done |
| Forensic snapshot for legal/audit | 0 | infra | ✓ done at `/home/gjovanov/.security-audit/2026-04-30/` |
| Stop, disable, purge Ollama service + binary + models + user | 2 | infra | ✓ done; 52 GB recovered |
| Decide & action `frps.service` on mars (disable / re-cred / restrict) | 3 | **PENDING USER DECISION** | open |
| Default-deny INPUT/FORWARD on mars/zeus/jupiter via Ansible role | 3 | infra | open |
| Restrict mars docker-proxy bindings to 127.0.0.1 (Mongo, lgr-*, bun) | 3 | infra | open |
| Re-enable UFW on the 6 VMs with minimal allow-lists | 3 | infra | open |
| `assert-no-ollama` task in Ansible (drift guard) | 4 | infra | open |
| Daily port allow-list audit + Prometheus alert | 4 | infra | open |
| Sudoers tightening (`PASSWD: ALL` for gjovanov + alazarovski) | 5 | infra | open |
| SSH `AllowTcpForwarding local`, `MaxAuthTries 3`, etc. | 5 | infra | open |
| `fail2ban` for SSH on hosts + VMs | 5 | infra | open |
| `auditd` on bare-metal hosts | 5 | infra | open |
| `unattended-upgrades` on Ubuntu hosts | 5 | infra | open |
| Sysctl hardening (rp_filter, syncookies, no-redirects) | 5 | infra | open |

## Lessons

1. **Anything not in Ansible / GitOps doesn't exist for ops purposes** — it lives in a blind spot. Ollama was a 48 GB blind spot for 7 months.
2. **`0.0.0.0` is a smell.** The vast majority of services on this cluster's hosts and VMs should be bound to `127.0.0.1` or a specific internal IP. A grep for `0.0.0.0` listeners should be a regular hygiene task.
3. **`UFW status` is not a firewall design.** Mars accumulated 100+ rules across years. A tight, declarative allow-list managed by Ansible is needed.
4. **Defense in depth was missing.** Even if Ollama was installed, a default-deny INPUT/FORWARD posture would have prevented external reach. We had neither the listener-side hardening nor the network-side hardening.

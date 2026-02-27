# k8s-cluster-multi - Multi-Host HA Kubernetes Cluster

Ansible-automated deployment of a highly available Kubernetes 1.31 cluster across 3 Hetzner bare-metal hosts. Uses KVM/libvirt for VM provisioning, WireGuard for cross-host networking, HAProxy for API server load balancing, Cilium for CNI, and kube-prometheus-stack for monitoring. Includes 3-instance COTURN deployment for WebRTC relay with per-host iptables DNAT.

## Architecture

```
                      +-----------------+
                      |    Internet     |
                      +---+----+----+---+
                          |    |    |
              +-----------+    |    +-----------+
              |                |                |
     +--------v------+ +------v--------+ +-----v---------+
     |     mars       | |     zeus       | |    jupiter     |
     | 94.130.141.98  | | 5.9.157.226    | | 5.9.157.221   |
     |  wg: 10.10.0.1 | |  wg: 10.10.0.2 | |  wg: 10.10.0.3|
     |                | |                | |                |
     | master-1  .10  | | master-2  .10  | | master-3  .10  |
     | worker-1  .11  | | worker-2  .11  | | worker-3  .11  |
     | 10.10.10.0/24  | | 10.10.20.0/24  | | 10.10.30.0/24  |
     +-------+--------+ +-------+--------+ +-------+--------+
             |                   |                   |
             +------- WireGuard mesh (wg0) ---------+
```

See [docs/diagrams/01-topology.mmd](docs/diagrams/01-topology.mmd) for the full topology diagram.

### Hosts and VMs

| Host | Public IP | WG IP | VM | VM IP | Role | vCPU | RAM |
|------|-----------|-------|----|-------|------|------|-----|
| mars | 94.130.141.98 | 10.10.0.1 | k8s-master-1 | 10.10.10.10 | master | 2 | 8 GB |
| mars | 94.130.141.98 | 10.10.0.1 | k8s-worker-1 | 10.10.10.11 | worker | 4 | 32 GB |
| zeus | 5.9.157.226 | 10.10.0.2 | k8s-master-2 | 10.10.20.10 | master | 2 | 8 GB |
| zeus | 5.9.157.226 | 10.10.0.2 | k8s-worker-2 | 10.10.20.11 | worker | 12 | 96 GB |
| jupiter | 5.9.157.221 | 10.10.0.3 | k8s-master-3 | 10.10.30.10 | master | 2 | 8 GB |
| jupiter | 5.9.157.221 | 10.10.0.3 | k8s-worker-3 | 10.10.30.11 | worker | 12 | 96 GB |

### Key Design Decisions

- **HAProxy on every node** at `127.0.0.1:8443` load-balances to all 3 API servers on `:6443`. This means `kubeadm` uses `--control-plane-endpoint=127.0.0.1:8443` and every kubelet connects locally, eliminating single points of failure.
- **Cilium CNI** with VXLAN encapsulation (MTU 1370) handles pod networking across hosts via WireGuard tunnels.
- **COTURN** runs as 3 individual pods with `hostNetwork: true`, one pinned to each worker node. Host-level iptables DNAT forwards TURN/TURNS ports from the public IP to the worker VM.
- **SNI proxy** on mars handles `TURNS :443` for `coturn.roomler.live`, forwarding TLS traffic to the COTURN pod on worker-1.

## Prerequisites

1. **Ansible** (2.15+) with collections:
   ```bash
   make collections
   ```

2. **SSH access** to all 3 bare-metal hosts as `HOST_USER` (default: `gjovanov`). For zeus and jupiter (PuTTY-provisioned), convert keys first:
   ```bash
   # Place your PuTTY key at ~/.ssh/putty.ppk, then:
   make convert-putty-key
   ```

3. **Environment file** -- copy and edit:
   ```bash
   cp .env.example .env
   # Edit .env with your secrets (COTURN_AUTH_SECRET, GRAFANA_ADMIN_PASSWORD, SMTP credentials)
   ```

4. **Tools** (optional but recommended):
   - `kubectl` -- for cluster management
   - `helm` -- for chart operations
   - `puttygen` -- for PuTTY key conversion

5. **Preflight check**:
   ```bash
   make preflight
   ```

## Quick Start

```bash
# 1. Clone and enter the project
cd ~/k8s-cluster-multi

# 2. Install Ansible collections
make collections

# 3. Set up environment
cp .env.example .env
vim .env  # fill in secrets

# 4. (If needed) Convert PuTTY keys for zeus/jupiter
make convert-putty-key

# 5. Run preflight checks
make preflight

# 6. Deploy everything (all 15 phases)
make setup

# 7. Verify the cluster
make verify

# 8. Check cluster status
make status
```

Or run phases individually:

```bash
make phase0   # Teardown old cluster
make phase1   # Bootstrap hosts
# ... and so on through phase14
```

## Phase-by-Phase Guide

### Phase 0: Teardown Old Cluster
```bash
make phase0
```
Removes any previous single-host cluster artifacts (VMs, networks, configs) from mars. Safe to skip on fresh hosts.

### Phase 1: Host Bootstrap
```bash
make phase1
```
Creates the `HOST_USER` account on zeus and jupiter (mars already has it). Installs base packages, configures SSH authorized keys, sets up sudo.

### Phase 2: Generate SSH Keys
```bash
make phase2
```
Generates per-host ed25519 SSH key pairs in `files/ssh/{mars,zeus,jupiter}/`. These keys are used by Ansible and for VM access.

### Phase 3: Host Setup (KVM/libvirt)
```bash
make phase3
```
Installs KVM, QEMU, libvirt on all 3 hosts. Creates the `k8s-net` libvirt network with NAT and DHCP on `virbr1`. Downloads the Ubuntu 22.04 cloud image.

### Phase 4: WireGuard Mesh
```bash
make phase4
```
Generates WireGuard keys, deploys `wg0` interface on each host. Establishes full-mesh peering between mars (10.10.0.1), zeus (10.10.0.2), and jupiter (10.10.0.3). Adds routes so each host can reach the other hosts' VM subnets through the WireGuard tunnel.

### Phase 5: VM Provisioning
```bash
make phase5
```
Creates 6 VMs (2 per host) using cloud-init and virt-install. Each VM gets a static IP, proper hostname, SSH keys, and routes to remote subnets via its host gateway. Waits for SSH connectivity before proceeding.

### Phase 6: HAProxy
```bash
make phase6
```
Installs HAProxy on all 6 VMs. Configures TCP-mode load balancing from `127.0.0.1:8443` to all 3 master API servers on `:6443`. This is the control plane endpoint used by kubeadm.

### Phase 7: K8s Prerequisites
```bash
make phase7
```
Installs containerd, kubeadm, kubelet, and kubectl on all 6 VMs. Configures kernel modules (`br_netfilter`, `overlay`), sysctl settings, and the Kubernetes apt repository for v1.31.

### Phase 8: K8s HA Masters
```bash
make phase8
```
Runs `kubeadm init` on master-1 with `--control-plane-endpoint=127.0.0.1:8443`. Installs Cilium 1.16.5 via Helm (VXLAN, MTU 1370, 2 operator replicas). Joins master-2 and master-3 to the control plane. Retrieves kubeconfig to `files/kubeconfig`.

### Phase 9: K8s Workers
```bash
make phase9
```
Joins worker-1, worker-2, and worker-3 to the cluster using the kubeadm join token. Labels worker nodes.

### Phase 10: COTURN Deploy
```bash
make phase10
```
Creates the `coturn` namespace. Copies TLS certificates to worker nodes. Deploys 3 COTURN pods with `hostNetwork: true`, each pinned to its respective worker via node affinity. Configures TURN (3478), TURNS (5349), alt-TLS (443), and relay ports (10000-13000).

### Phase 11: Host Networking
```bash
make phase11
```
Configures iptables on each bare-metal host: DNAT chains (`COTURN_DNAT`) forward TURN/TURNS traffic from the public IP to the worker VM. SNAT chains handle return traffic. Installs a systemd service (`coturn-iptables.service`) for persistence across reboots. Deploys the SNI proxy on mars for TURNS:443 (`coturn.roomler.live`).

### Phase 12: Host kubectl + HAProxy
```bash
make phase12
```
Installs kubectl on all bare-metal hosts and distributes the kubeconfig. Optionally installs HAProxy on hosts for direct API access.

### Phase 13: Monitoring
```bash
make phase13
```
Deploys kube-prometheus-stack (Helm chart v65.1.0) into the `monitoring` namespace. Configures Prometheus (14d retention, 10Gi storage), Grafana (NodePort 30300), and AlertManager (SendGrid SMTP email alerts). Includes a custom COTURN Grafana dashboard.

### Phase 14: Verify
```bash
make phase14
```
Runs automated health checks: VM status, WireGuard peers, cross-host connectivity, K8s node readiness, Cilium agents, COTURN pods, iptables rules, and monitoring stack.

## Diagrams

All diagrams are in Mermaid format. View them with any Mermaid-compatible renderer (GitHub, VS Code extension, mermaid.live).

| # | File | Description |
|---|------|-------------|
| 1 | [01-topology.mmd](docs/diagrams/01-topology.mmd) | Physical topology: 3 hosts, 6 VMs, WireGuard connections |
| 2 | [02-network.mmd](docs/diagrams/02-network.mmd) | IP addressing: public IPs, WireGuard IPs, VM subnets, K8s overlay |
| 3 | [03-wireguard-mesh.mmd](docs/diagrams/03-wireguard-mesh.mmd) | WireGuard mesh: peers, AllowedIPs, subnet routing |
| 4 | [04-ha-control-plane.mmd](docs/diagrams/04-ha-control-plane.mmd) | HA control plane: HAProxy -> API servers, etcd cluster, Cilium |
| 5 | [05-coturn-flow.mmd](docs/diagrams/05-coturn-flow.mmd) | COTURN traffic flow: client -> public IP -> iptables -> worker -> pod |
| 6 | [06-deployment-phases.mmd](docs/diagrams/06-deployment-phases.mmd) | Deployment phases 0-14 flowchart with dependencies |
| 7 | [07-vm-provisioning.mmd](docs/diagrams/07-vm-provisioning.mmd) | VM provisioning: cloud image -> qcow2 -> cloud-init -> virt-install |
| 8 | [08-monitoring.mmd](docs/diagrams/08-monitoring.mmd) | Monitoring stack: Prometheus, Grafana, AlertManager |

## Configuration

### Environment Variables (.env)

Copy `.env.example` to `.env` and fill in values:

| Variable | Description | Default |
|----------|-------------|---------|
| `HOST_USER` | SSH user on bare-metal hosts | `gjovanov` |
| `HOME_DIR` | Home directory path | `/home/HOST_USER` |
| `MARS_PUBLIC_IP` | Mars public IP | `94.130.141.98` |
| `ZEUS_PUBLIC_IP` | Zeus public IP | `5.9.157.226` |
| `JUPITER_PUBLIC_IP` | Jupiter public IP | `5.9.157.221` |
| `COTURN_AUTH_SECRET` | COTURN shared secret | (required) |
| `COTURN_REALM` | COTURN realm | `roomler.live` |
| `COTURN_TLS_CERT` | Path to TLS fullchain | `HOME_DIR/cert/roomler.live.fullchain.pem` |
| `COTURN_TLS_KEY` | Path to TLS private key | `HOME_DIR/cert/roomler.live.key.pem` |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password | (required) |
| `SMTP_USER` | SendGrid SMTP user | `apikey` |
| `SMTP_PASSWORD` | SendGrid API key | (required) |
| `ALERTMANAGER_EMAIL_TO` | Alert recipient | `goran.jovanov@gmail.com` |
| `ALERTMANAGER_EMAIL_FROM` | Alert sender address | `alerts@roomler.live` |
| `SNI_PROXY_HOSTNAME` | SNI proxy hostname | `coturn.roomler.live` |
| `SNI_PROXY_DOCKER_CONTAINER` | Docker container for SNI | `nginx` |

### Key Files

| Path | Description |
|------|-------------|
| `files/ssh/mars/k8s_ed25519` | SSH private key for mars VMs |
| `files/ssh/zeus/k8s_ed25519` | SSH private key for zeus VMs |
| `files/ssh/jupiter/k8s_ed25519` | SSH private key for jupiter VMs |
| `files/kubeconfig` | Cluster kubeconfig (generated by phase 8) |
| `files/wireguard/` | WireGuard keys (generated by phase 4) |
| `inventory/hosts.yml` | Ansible inventory |
| `inventory/group_vars/all.yml` | All variables and defaults |

## SSH Access

### Bare-Metal Hosts

```bash
make ssh-mars      # SSH to mars (94.130.141.98)
make ssh-zeus      # SSH to zeus (5.9.157.226)
make ssh-jupiter   # SSH to jupiter (5.9.157.221)
```

### VMs (via ProxyJump for remote hosts)

```bash
make ssh-master-1  # master-1 on mars (direct, 10.10.10.10)
make ssh-master-2  # master-2 on zeus (via ProxyJump, 10.10.20.10)
make ssh-master-3  # master-3 on jupiter (via ProxyJump, 10.10.30.10)
make ssh-worker-1  # worker-1 on mars (direct, 10.10.10.11)
make ssh-worker-2  # worker-2 on zeus (via ProxyJump, 10.10.20.11)
make ssh-worker-3  # worker-3 on jupiter (via ProxyJump, 10.10.30.11)
```

Mars VMs are accessed directly (mars is the local host). Zeus and Jupiter VMs require ProxyJump through their respective bare-metal host.

### kubectl

```bash
# Via Makefile
make kubectl ARGS="get nodes"
make kubectl ARGS="get pods -A"

# Or directly
kubectl --kubeconfig=files/kubeconfig get nodes -o wide
```

## Verification

### Automated Verification

```bash
# Full verification script (9 test categories)
make verify

# Quick cluster status
make status
```

The `make verify` script checks:

1. **VM Health** -- 2 VMs running per host (6 total)
2. **WireGuard Mesh** -- 2 peers per host with recent handshakes
3. **Cross-host VM Connectivity** -- ping from mars VMs to zeus/jupiter VMs
4. **K8s Cluster** -- 6 nodes, all Ready
5. **Cilium CNI** -- 6 agents running, operator running
6. **COTURN Pods** -- 3 pods Running (one per worker)
7. **COTURN Port Reachability** -- ports 3478, 5349 reachable on all public IPs
8. **iptables Rules** -- COTURN_DNAT chain present on each host
9. **Monitoring Stack** -- Prometheus, Grafana, AlertManager pods running

### Manual Checks

```bash
# Check nodes
kubectl --kubeconfig=files/kubeconfig get nodes -o wide

# Check all pods
kubectl --kubeconfig=files/kubeconfig get pods -A

# Check Cilium status
kubectl --kubeconfig=files/kubeconfig -n kube-system get pods -l app.kubernetes.io/name=cilium-agent

# Check etcd health (from any master)
make ssh-master-1
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  member list --write-out=table

# Check WireGuard (from any host)
make ssh-mars
sudo wg show wg0

# Check COTURN ports
for ip in 94.130.141.98 5.9.157.226 5.9.157.221; do
  echo "=== $ip ==="
  timeout 3 bash -c "echo | openssl s_client -connect ${ip}:5349 2>/dev/null | head -5"
done

# Access Grafana
make grafana-tunnel
# Then open http://localhost:3000 in your browser
```

## Teardown

```bash
# Full teardown: VMs, WireGuard, iptables, kubeconfig
make teardown

# Keep VMs, only remove K8s namespaces and iptables
make teardown-keep-vms

# Teardown a single host
make teardown-host HOST=zeus
```

Teardown options (passed to `scripts/teardown.sh`):

| Flag | Effect |
|------|--------|
| `--keep-iptables` | Preserve iptables rules |
| `--keep-vms` | Keep VMs, only clean K8s/iptables |
| `--keep-wireguard` | Keep WireGuard mesh |
| `--host HOST` | Only teardown on specific host (mars, zeus, or jupiter) |

## Troubleshooting

### SSH Connection Refused to Remote VMs

Remote VMs (zeus, jupiter) require ProxyJump through the bare-metal host. If direct SSH fails:

```bash
# Correct way (via ProxyJump)
ssh -i files/ssh/zeus/k8s_ed25519 -o ProxyJump=HOST_USER@5.9.157.226 ubuntu@10.10.20.10

# Check WireGuard is up
ssh HOST_USER@5.9.157.226 "sudo wg show wg0"
```

### VMs Not Reachable After Reboot

Check that libvirt network and VMs auto-start:

```bash
ssh HOST_USER@HOSTIP "sudo virsh net-list --all"
ssh HOST_USER@HOSTIP "sudo virsh list --all"
ssh HOST_USER@HOSTIP "sudo virsh net-start k8s-net"
ssh HOST_USER@HOSTIP "sudo virsh start k8s-master-N"
```

### WireGuard Peers Not Connecting

```bash
# Check interface is up
sudo wg show wg0

# Check firewall allows UDP 51820
sudo iptables -L INPUT -n | grep 51820

# Check endpoint resolution
sudo wg show wg0 endpoints

# Restart WireGuard
sudo systemctl restart wg-quick@wg0
```

### kubeadm Join Fails

```bash
# Regenerate join token from master-1
kubeadm token create --print-join-command

# Check HAProxy is running and forwarding
systemctl status haproxy
curl -k https://127.0.0.1:8443/healthz

# Verify all 3 masters are reachable from the joining node
for ip in 10.10.10.10 10.10.20.10 10.10.30.10; do
  echo "$ip:"; timeout 3 bash -c "echo | openssl s_client -connect ${ip}:6443 2>/dev/null | head -3"
done
```

### Cilium Pods CrashLooping

```bash
# Check Cilium agent logs
kubectl --kubeconfig=files/kubeconfig -n kube-system logs -l app.kubernetes.io/name=cilium-agent --tail=50

# Verify MTU is consistent (should be 1370 for VXLAN over WireGuard)
kubectl --kubeconfig=files/kubeconfig -n kube-system exec ds/cilium -- cilium status

# Common fix: restart Cilium
kubectl --kubeconfig=files/kubeconfig -n kube-system rollout restart daemonset/cilium
```

### COTURN Ports Not Reachable

```bash
# Check pod is running
kubectl --kubeconfig=files/kubeconfig -n coturn get pods -o wide

# Check iptables DNAT rules on the host
ssh HOST_USER@HOSTIP "sudo iptables -t nat -L COTURN_DNAT -n -v"

# Check the systemd persistence service
ssh HOST_USER@HOSTIP "sudo systemctl status coturn-iptables.service"

# Manually test from the host
ssh HOST_USER@HOSTIP "nc -zv 10.10.X.11 3478"
```

### Grafana Not Accessible

```bash
# Check the pod is running
kubectl --kubeconfig=files/kubeconfig -n monitoring get pods | grep grafana

# Open SSH tunnel (Grafana is on NodePort 30300 on worker-1)
make grafana-tunnel
# Access at http://localhost:3000

# Default credentials: admin / (your GRAFANA_ADMIN_PASSWORD)
```

### etcd Cluster Unhealthy

```bash
# Check etcd member list from master-1
make ssh-master-1
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://10.10.10.10:2379,https://10.10.20.10:2379,https://10.10.30.10:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint health --write-out=table
```

## IP Reference Table

### Bare-Metal Hosts

| Host | Public IP | WireGuard IP | VM Bridge | VM Subnet |
|------|-----------|-------------|-----------|-----------|
| mars | 94.130.141.98 | 10.10.0.1 | virbr1 / 10.10.10.1 | 10.10.10.0/24 |
| zeus | 5.9.157.226 | 10.10.0.2 | virbr1 / 10.10.20.1 | 10.10.20.0/24 |
| jupiter | 5.9.157.221 | 10.10.0.3 | virbr1 / 10.10.30.1 | 10.10.30.0/24 |

### Virtual Machines

| VM | IP | Host | Role | vCPU | RAM | Disk |
|----|-----|------|------|------|-----|------|
| k8s-master-1 | 10.10.10.10 | mars | control-plane | 2 | 8 GB | 40 GB |
| k8s-worker-1 | 10.10.10.11 | mars | worker | 4 | 32 GB | 100 GB |
| k8s-master-2 | 10.10.20.10 | zeus | control-plane | 2 | 8 GB | 40 GB |
| k8s-worker-2 | 10.10.20.11 | zeus | worker | 12 | 96 GB | 200 GB |
| k8s-master-3 | 10.10.30.10 | jupiter | control-plane | 2 | 8 GB | 40 GB |
| k8s-worker-3 | 10.10.30.11 | jupiter | worker | 12 | 96 GB | 200 GB |

### Kubernetes Networks

| Network | CIDR | Purpose |
|---------|------|---------|
| Pod CIDR | 10.244.0.0/16 | Cilium-managed pod IPs (VXLAN) |
| Service CIDR | 10.96.0.0/12 | ClusterIP services |

### Service Ports

| Service | Port | Protocol | Description |
|---------|------|----------|-------------|
| K8s API (via HAProxy) | 127.0.0.1:8443 | TCP | Local load-balanced endpoint |
| K8s API (direct) | :6443 | TCP | Per-master API server |
| etcd client | :2379 | TCP | etcd client connections |
| etcd peer | :2380 | TCP | etcd peer communication |
| WireGuard | :51820 | UDP | WireGuard tunnel |
| TURN | :3478 | TCP/UDP | COTURN TURN |
| TURNS | :5349 | TCP | COTURN TURNS (TLS) |
| COTURN alt-TLS | :443 | TCP | TURNS over 443 |
| COTURN relay | :10000-13000 | UDP | Media relay ports |
| SNI Proxy | :4443 | TCP | nginx SNI proxy (mars only) |
| Grafana | NodePort 30300 | TCP | Grafana dashboard |

### COTURN Routing

| Host | Public IP | DNAT Target | Worker |
|------|-----------|-------------|--------|
| mars | 94.130.141.98 | 10.10.10.11 | k8s-worker-1 |
| zeus | 5.9.157.226 | 10.10.20.11 | k8s-worker-2 |
| jupiter | 5.9.157.221 | 10.10.30.11 | k8s-worker-3 |

## Project Structure

```
k8s-cluster-multi/
  Makefile                          # All make targets
  .env.example                      # Environment template
  .env                              # Your secrets (git-ignored)
  ansible.cfg                       # Ansible configuration
  inventory/
    hosts.yml                       # Host/VM inventory
    group_vars/
      all.yml                       # Variables and defaults
  playbooks/
    site.yml                        # Master playbook (all phases)
    00-teardown-old.yml             # Phase 0
    01-host-bootstrap.yml           # Phase 1
    ...                             # Phases 2-14
  roles/
    host-bootstrap/                 # User creation, packages
    host-setup/                     # KVM, libvirt, cloud image
    wireguard/                      # WireGuard mesh
    vm-provision/                   # Cloud-init VM creation
    haproxy/                        # HAProxy load balancer
    k8s-common/                     # containerd, kubeadm, kubelet
    k8s-master/                     # kubeadm init/join, Cilium
    k8s-worker/                     # Worker node join
    coturn/                         # COTURN pod deployment
    host-networking/                # iptables DNAT/SNAT
    sni-proxy/                      # nginx SNI proxy (mars)
    monitoring/                     # kube-prometheus-stack
  scripts/
    verify-cluster.sh               # Health check script
    teardown.sh                     # Teardown script
  files/
    ssh/{mars,zeus,jupiter}/        # Per-host SSH keys
    kubeconfig                      # Cluster kubeconfig
    wireguard/                      # WireGuard keys
  docs/
    diagrams/                       # Mermaid architecture diagrams
  backup/
    iptables-backup.rules           # iptables backup
```

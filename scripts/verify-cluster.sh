#!/bin/bash
# Comprehensive cluster health check for k8s-cluster-multi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG="${PROJECT_DIR}/files/kubeconfig"

# Load .env if present
if [ -f "${PROJECT_DIR}/.env" ]; then
  set -a; source "${PROJECT_DIR}/.env"; set +a
fi

HOST_USER="${HOST_USER:-deployer}"
HOME_DIR="${HOME_DIR:-/home/${HOST_USER}}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}PASS${NC} $1"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}WARN${NC} $1"; ((WARN++)); }

HOSTS=(
  "mars:${MARS_PUBLIC_IP:-198.51.100.10}"
  "zeus:${ZEUS_PUBLIC_IP:-198.51.100.20}"
  "jupiter:${JUPITER_PUBLIC_IP:-198.51.100.30}"
)

VM_SUBNETS=(
  "mars:10.10.10"
  "zeus:10.10.20"
  "jupiter:10.10.30"
)

# ---- 1. VM Health ----
echo ""
echo "=== 1. VM Health ==="
for entry in "${HOSTS[@]}"; do
  host="${entry%%:*}"
  ip="${entry##*:}"
  vm_count=$(ssh -o ConnectTimeout=5 "${HOST_USER}@${ip}" "virsh list --state-running 2>/dev/null | grep -c 'running'" 2>/dev/null || echo "0")
  if [ "$vm_count" -ge 2 ]; then
    pass "$host: $vm_count VMs running"
  else
    fail "$host: only $vm_count VMs running (expected 2)"
  fi
done

# ---- 2. WireGuard ----
echo ""
echo "=== 2. WireGuard Mesh ==="
for entry in "${HOSTS[@]}"; do
  host="${entry%%:*}"
  ip="${entry##*:}"
  peers=$(ssh -o ConnectTimeout=5 "${HOST_USER}@${ip}" "sudo wg show wg0 2>/dev/null | grep -c 'peer:'" 2>/dev/null || echo "0")
  handshakes=$(ssh -o ConnectTimeout=5 "${HOST_USER}@${ip}" "sudo wg show wg0 2>/dev/null | grep -c 'latest handshake'" 2>/dev/null || echo "0")
  if [ "$peers" -ge 2 ] && [ "$handshakes" -ge 2 ]; then
    pass "$host: $peers peers, $handshakes handshakes"
  elif [ "$peers" -ge 2 ]; then
    warn "$host: $peers peers but only $handshakes handshakes"
  else
    fail "$host: only $peers peers (expected 2)"
  fi
done

# ---- 3. Cross-host VM Connectivity ----
echo ""
echo "=== 3. Cross-host VM Connectivity ==="
MARS_IP="${MARS_PUBLIC_IP:-198.51.100.10}"
# Test from mars master-1 to zeus master-2
if ssh -o ConnectTimeout=5 "${HOST_USER}@${MARS_IP}" "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ${PROJECT_DIR}/files/ssh/mars/k8s_ed25519 ubuntu@10.10.10.10 'ping -c 1 -W 3 10.10.20.10'" &>/dev/null; then
  pass "master-1 (mars) -> master-2 (zeus)"
else
  fail "master-1 (mars) -> master-2 (zeus)"
fi
# Test from mars master-1 to jupiter master-3
if ssh -o ConnectTimeout=5 "${HOST_USER}@${MARS_IP}" "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ${PROJECT_DIR}/files/ssh/mars/k8s_ed25519 ubuntu@10.10.10.10 'ping -c 1 -W 3 10.10.30.10'" &>/dev/null; then
  pass "master-1 (mars) -> master-3 (jupiter)"
else
  fail "master-1 (mars) -> master-3 (jupiter)"
fi

# ---- 4. K8s Cluster ----
echo ""
echo "=== 4. K8s Cluster ==="
if [ -f "$KUBECONFIG" ]; then
  NODE_COUNT=$(kubectl --kubeconfig="$KUBECONFIG" get nodes --no-headers 2>/dev/null | wc -l || echo "0")
  READY_COUNT=$(kubectl --kubeconfig="$KUBECONFIG" get nodes --no-headers 2>/dev/null | grep -c ' Ready' || echo "0")
  if [ "$NODE_COUNT" -ge 6 ] && [ "$READY_COUNT" -ge 6 ]; then
    pass "Cluster: $NODE_COUNT nodes, $READY_COUNT ready"
  elif [ "$NODE_COUNT" -ge 6 ]; then
    warn "Cluster: $NODE_COUNT nodes but only $READY_COUNT ready"
  else
    fail "Cluster: only $NODE_COUNT nodes (expected 6)"
  fi

  MASTER_COUNT=$(kubectl --kubeconfig="$KUBECONFIG" get nodes --no-headers -l node-role.kubernetes.io/control-plane 2>/dev/null | wc -l || echo "0")
  if [ "$MASTER_COUNT" -ge 3 ]; then
    pass "Control plane: $MASTER_COUNT masters"
  else
    fail "Control plane: only $MASTER_COUNT masters (expected 3)"
  fi
else
  fail "Kubeconfig not found at $KUBECONFIG"
fi

# ---- 5. Cilium CNI ----
echo ""
echo "=== 5. Cilium CNI ==="
if [ -f "$KUBECONFIG" ]; then
  CILIUM_READY=$(kubectl --kubeconfig="$KUBECONFIG" -n kube-system get pods -l app.kubernetes.io/name=cilium-agent --no-headers 2>/dev/null | grep -c 'Running' || echo "0")
  CILIUM_OP=$(kubectl --kubeconfig="$KUBECONFIG" -n kube-system get pods -l app.kubernetes.io/name=cilium-operator --no-headers 2>/dev/null | grep -c 'Running' || echo "0")
  if [ "$CILIUM_READY" -ge 6 ]; then
    pass "Cilium agents: $CILIUM_READY running"
  else
    warn "Cilium agents: only $CILIUM_READY running (expected 6)"
  fi
  if [ "$CILIUM_OP" -ge 1 ]; then
    pass "Cilium operator: $CILIUM_OP running"
  else
    fail "Cilium operator: not running"
  fi
fi

# ---- 6. COTURN ----
echo ""
echo "=== 6. COTURN Pods ==="
if [ -f "$KUBECONFIG" ]; then
  for i in 1 2 3; do
    POD_STATUS=$(kubectl --kubeconfig="$KUBECONFIG" -n coturn get pod -l instance=coturn-worker-${i} --no-headers 2>/dev/null | awk '{print $3}' || echo "NotFound")
    if [ "$POD_STATUS" = "Running" ]; then
      pass "coturn-worker-${i}: Running"
    else
      fail "coturn-worker-${i}: $POD_STATUS"
    fi
  done
fi

# ---- 7. COTURN Port Reachability ----
echo ""
echo "=== 7. COTURN Port Reachability ==="
for entry in "${HOSTS[@]}"; do
  host="${entry%%:*}"
  ip="${entry##*:}"
  for port in 3478 5349; do
    if timeout 3 bash -c "echo > /dev/tcp/${ip}/${port}" 2>/dev/null; then
      pass "$host ($ip):$port reachable"
    else
      fail "$host ($ip):$port not reachable"
    fi
  done
done

# ---- 8. iptables Rules ----
echo ""
echo "=== 8. iptables Rules ==="
for entry in "${HOSTS[@]}"; do
  host="${entry%%:*}"
  ip="${entry##*:}"
  dnat_count=$(ssh -o ConnectTimeout=5 "${HOST_USER}@${ip}" "sudo iptables -t nat -L COTURN_DNAT -n 2>/dev/null | grep -c DNAT" 2>/dev/null || echo "0")
  if [ "$dnat_count" -gt 0 ]; then
    pass "$host: $dnat_count DNAT rules"
  else
    fail "$host: no COTURN_DNAT rules"
  fi
done

# ---- 9. Monitoring ----
echo ""
echo "=== 9. Monitoring Stack ==="
if [ -f "$KUBECONFIG" ]; then
  for component in prometheus grafana alertmanager; do
    COUNT=$(kubectl --kubeconfig="$KUBECONFIG" -n monitoring get pods --no-headers 2>/dev/null | grep -c "$component" || echo "0")
    if [ "$COUNT" -gt 0 ]; then
      pass "$component: $COUNT pod(s)"
    else
      warn "$component: not found"
    fi
  done
fi

# ---- Summary ----
echo ""
echo "========================================"
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}WARN: $WARN${NC}"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

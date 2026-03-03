#!/bin/bash
# Teardown script for k8s-cluster-multi
# Destroys VMs, removes WireGuard, cleans iptables on all hosts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env if present
if [ -f "${PROJECT_DIR}/.env" ]; then
  set -a; source "${PROJECT_DIR}/.env"; set +a
fi

HOST_USER="${HOST_USER:-deployer}"
MARS_IP="${MARS_PUBLIC_IP:-198.51.100.10}"
ZEUS_IP="${ZEUS_PUBLIC_IP:-198.51.100.20}"
JUPITER_IP="${JUPITER_PUBLIC_IP:-198.51.100.30}"

KEEP_IPTABLES=false
KEEP_VMS=false
KEEP_WIREGUARD=false
HOST_FILTER=""

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "  --keep-iptables    Keep iptables rules"
  echo "  --keep-vms         Keep VMs (only clean K8s/iptables)"
  echo "  --keep-wireguard   Keep WireGuard mesh"
  echo "  --host HOST        Only teardown on specific host (mars|zeus|jupiter)"
  echo "  -h, --help         Show this help"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --keep-iptables) KEEP_IPTABLES=true; shift ;;
    --keep-vms) KEEP_VMS=true; shift ;;
    --keep-wireguard) KEEP_WIREGUARD=true; shift ;;
    --host) HOST_FILTER="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

declare -A HOST_IPS=(
  [mars]="$MARS_IP"
  [zeus]="$ZEUS_IP"
  [jupiter]="$JUPITER_IP"
)

declare -A HOST_VMS=(
  [mars]="k8s-master-1 k8s-worker-1"
  [zeus]="k8s-master-2 k8s-worker-2"
  [jupiter]="k8s-master-3 k8s-worker-3"
)

teardown_host() {
  local host="$1"
  local ip="${HOST_IPS[$host]}"
  echo ""
  echo "=== Tearing down $host ($ip) ==="

  # Delete K8s namespaces (only from mars/master-1)
  if [ "$host" = "mars" ] && [ -f "${PROJECT_DIR}/files/kubeconfig" ]; then
    echo "  Deleting K8s namespaces..."
    kubectl --kubeconfig="${PROJECT_DIR}/files/kubeconfig" delete namespace coturn --ignore-not-found=true 2>/dev/null || true
    kubectl --kubeconfig="${PROJECT_DIR}/files/kubeconfig" delete namespace monitoring --ignore-not-found=true 2>/dev/null || true
  fi

  # Remove iptables rules
  if [ "$KEEP_IPTABLES" = false ]; then
    echo "  Removing iptables rules..."
    ssh "${HOST_USER}@${ip}" "
      sudo iptables -t nat -D PREROUTING -j COTURN_DNAT 2>/dev/null || true
      sudo iptables -t nat -F COTURN_DNAT 2>/dev/null || true
      sudo iptables -t nat -X COTURN_DNAT 2>/dev/null || true
      sudo iptables -t nat -D OUTPUT -j COTURN_OUTPUT_DNAT 2>/dev/null || true
      sudo iptables -t nat -F COTURN_OUTPUT_DNAT 2>/dev/null || true
      sudo iptables -t nat -X COTURN_OUTPUT_DNAT 2>/dev/null || true
      sudo iptables -t nat -D POSTROUTING -j COTURN_SNAT 2>/dev/null || true
      sudo iptables -t nat -F COTURN_SNAT 2>/dev/null || true
      sudo iptables -t nat -X COTURN_SNAT 2>/dev/null || true
      sudo systemctl disable coturn-iptables.service 2>/dev/null || true
      sudo rm -f /usr/local/bin/coturn-iptables.sh
      sudo rm -f /etc/systemd/system/coturn-iptables.service
      sudo iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    " 2>/dev/null || true
  fi

  # Remove WireGuard
  if [ "$KEEP_WIREGUARD" = false ]; then
    echo "  Removing WireGuard..."
    ssh "${HOST_USER}@${ip}" "
      sudo systemctl stop wg-quick@wg0 2>/dev/null || true
      sudo systemctl disable wg-quick@wg0 2>/dev/null || true
      sudo rm -f /etc/wireguard/wg0.conf
      sudo rm -f /usr/local/bin/wg-postup.sh /usr/local/bin/wg-postdown.sh
    " 2>/dev/null || true
  fi

  # Destroy VMs
  if [ "$KEEP_VMS" = false ]; then
    echo "  Destroying VMs..."
    for vm in ${HOST_VMS[$host]}; do
      ssh "${HOST_USER}@${ip}" "
        sudo virsh destroy ${vm} 2>/dev/null || true
        sudo virsh undefine ${vm} --remove-all-storage 2>/dev/null || true
        sudo rm -rf /var/lib/libvirt/cloud-init/${vm}
      " 2>/dev/null || true
      echo "    Destroyed $vm"
    done

    # Destroy libvirt network
    echo "  Removing libvirt network..."
    ssh "${HOST_USER}@${ip}" "
      sudo virsh net-destroy k8s-net 2>/dev/null || true
      sudo virsh net-undefine k8s-net 2>/dev/null || true
    " 2>/dev/null || true
  fi

  echo "  Done: $host"
}

echo "K8s Cluster Multi - Teardown"
echo "============================"
echo "Options: keep-iptables=$KEEP_IPTABLES, keep-vms=$KEEP_VMS, keep-wireguard=$KEEP_WIREGUARD"

if [ -n "$HOST_FILTER" ]; then
  teardown_host "$HOST_FILTER"
else
  for host in mars zeus jupiter; do
    teardown_host "$host"
  done
fi

# Clean local files
if [ "$KEEP_VMS" = false ]; then
  echo ""
  echo "Cleaning local files..."
  rm -f "${PROJECT_DIR}/files/kubeconfig"
  echo "  Removed kubeconfig"
fi

echo ""
echo "Teardown complete."

.PHONY: help preflight collections setup verify teardown status
.PHONY: phase0 phase1 phase2 phase3 phase4 phase5 phase6 phase7 phase8 phase9 phase10 phase11 phase12 phase13 phase14
.PHONY: ssh-master-1 ssh-master-2 ssh-master-3 ssh-worker-1 ssh-worker-2 ssh-worker-3
.PHONY: kubectl grafana-tunnel convert-putty-key

SHELL := /bin/bash
PLAYBOOKS := playbooks
SCRIPTS := scripts
SSH_DIR := files/ssh
ENV_FILE := .env

# Load .env if present
ifneq (,$(wildcard $(ENV_FILE)))
  include $(ENV_FILE)
  export
endif

HOST_USER ?= deployer
HOME_DIR ?= /home/$(HOST_USER)
MARS_IP ?= 198.51.100.10
ZEUS_IP ?= 198.51.100.20
JUPITER_IP ?= 198.51.100.30

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

preflight: ## Check prerequisites
	@echo "=== Preflight Checks ==="
	@command -v ansible-playbook >/dev/null && echo "  OK: ansible-playbook" || echo "  MISSING: ansible-playbook"
	@command -v ssh >/dev/null && echo "  OK: ssh" || echo "  MISSING: ssh"
	@command -v kubectl >/dev/null && echo "  OK: kubectl" || echo "  MISSING: kubectl (optional)"
	@command -v helm >/dev/null && echo "  OK: helm" || echo "  MISSING: helm (optional)"
	@command -v puttygen >/dev/null && echo "  OK: puttygen" || echo "  MISSING: puttygen (optional, for .ppk conversion)"
	@test -f $(ENV_FILE) && echo "  OK: .env file" || echo "  MISSING: .env file (copy from .env.example)"
	@echo ""
	@echo "SSH connectivity:"
	@ssh -o ConnectTimeout=5 -o BatchMode=yes $(HOST_USER)@$(MARS_IP) "echo '  OK: mars'" 2>/dev/null || echo "  FAIL: mars ($(MARS_IP))"
	@ssh -o ConnectTimeout=5 -o BatchMode=yes $(HOST_USER)@$(ZEUS_IP) "echo '  OK: zeus'" 2>/dev/null || echo "  FAIL: zeus ($(ZEUS_IP))"
	@ssh -o ConnectTimeout=5 -o BatchMode=yes $(HOST_USER)@$(JUPITER_IP) "echo '  OK: jupiter'" 2>/dev/null || echo "  FAIL: jupiter ($(JUPITER_IP))"

collections: ## Install Ansible collections
	ansible-galaxy collection install ansible.posix community.general kubernetes.core --force

convert-putty-key: ## Convert PuTTY .ppk to OpenSSH format (for bootstrap)
	@echo "Converting ~/.ssh/putty.ppk to OpenSSH format for bootstrap..."
	@test -f ~/.ssh/putty.ppk || (echo "ERROR: ~/.ssh/putty.ppk not found" && exit 1)
	@mkdir -p $(SSH_DIR)/bootstrap
	puttygen ~/.ssh/putty.ppk -O private-openssh -o $(SSH_DIR)/bootstrap/id_ed25519
	chmod 600 $(SSH_DIR)/bootstrap/id_ed25519
	ssh-keygen -y -f $(SSH_DIR)/bootstrap/id_ed25519 > $(SSH_DIR)/bootstrap/id_ed25519.pub
	@echo ""
	@echo "Done. Bootstrap key saved to $(SSH_DIR)/bootstrap/id_ed25519"
	@echo "Test with: ssh -i $(SSH_DIR)/bootstrap/id_ed25519 root@$(ZEUS_IP)"
	@echo "Test with: ssh -i $(SSH_DIR)/bootstrap/id_ed25519 root@$(JUPITER_IP)"

setup: ## Full setup (all phases 0-14)
	ansible-playbook $(PLAYBOOKS)/site.yml

phase0: ## Phase 0: Tear down old cluster
	ansible-playbook $(PLAYBOOKS)/00-teardown-old.yml

phase1: ## Phase 1: Bootstrap new hosts
	ansible-playbook $(PLAYBOOKS)/01-host-bootstrap.yml

phase2: ## Phase 2: Generate SSH keys
	ansible-playbook $(PLAYBOOKS)/02-generate-ssh-keys.yml

phase3: ## Phase 3: Host setup (KVM/libvirt)
	ansible-playbook $(PLAYBOOKS)/03-host-setup.yml

phase4: ## Phase 4: WireGuard mesh
	ansible-playbook $(PLAYBOOKS)/04-wireguard.yml

phase5: ## Phase 5: VM provisioning
	ansible-playbook $(PLAYBOOKS)/05-vm-provision.yml

phase6: ## Phase 6: HAProxy on VMs
	ansible-playbook $(PLAYBOOKS)/06-haproxy.yml

phase7: ## Phase 7: K8s prerequisites
	ansible-playbook $(PLAYBOOKS)/07-k8s-common.yml

phase8: ## Phase 8: K8s HA masters
	ansible-playbook $(PLAYBOOKS)/08-k8s-masters.yml

phase9: ## Phase 9: K8s workers
	ansible-playbook $(PLAYBOOKS)/09-k8s-workers.yml

phase10: ## Phase 10: COTURN deployment
	ansible-playbook $(PLAYBOOKS)/10-coturn-deploy.yml

phase11: ## Phase 11: Host networking (iptables)
	ansible-playbook $(PLAYBOOKS)/11-host-networking.yml

phase12: ## Phase 12: Host kubectl + HAProxy
	ansible-playbook $(PLAYBOOKS)/12-host-kubectl.yml

phase13: ## Phase 13: Monitoring
	ansible-playbook $(PLAYBOOKS)/13-monitoring.yml

phase14: ## Phase 14: Verify
	ansible-playbook $(PLAYBOOKS)/14-verify.yml

verify: ## Run verification script
	bash $(SCRIPTS)/verify-cluster.sh

teardown: ## Full teardown (VMs, WireGuard, iptables)
	bash $(SCRIPTS)/teardown.sh

teardown-keep-vms: ## Teardown keeping VMs
	bash $(SCRIPTS)/teardown.sh --keep-vms

teardown-host: ## Teardown single host (usage: make teardown-host HOST=zeus)
	bash $(SCRIPTS)/teardown.sh --host $(HOST)

status: ## Show cluster status
	@echo "=== Nodes ==="
	@kubectl --kubeconfig=files/kubeconfig get nodes -o wide 2>/dev/null || echo "No kubeconfig or cluster not reachable"
	@echo ""
	@echo "=== Pods ==="
	@kubectl --kubeconfig=files/kubeconfig get pods --all-namespaces 2>/dev/null || true

ssh-master-1: ## SSH to master-1 (mars)
	ssh -i $(SSH_DIR)/mars/k8s_ed25519 ubuntu@10.10.10.10

ssh-master-2: ## SSH to master-2 (zeus)
	ssh -i $(SSH_DIR)/zeus/k8s_ed25519 -o ProxyJump=$(HOST_USER)@$(ZEUS_IP) ubuntu@10.10.20.10

ssh-master-3: ## SSH to master-3 (jupiter)
	ssh -i $(SSH_DIR)/jupiter/k8s_ed25519 -o ProxyJump=$(HOST_USER)@$(JUPITER_IP) ubuntu@10.10.30.10

ssh-worker-1: ## SSH to worker-1 (mars)
	ssh -i $(SSH_DIR)/mars/k8s_ed25519 ubuntu@10.10.10.11

ssh-worker-2: ## SSH to worker-2 (zeus)
	ssh -i $(SSH_DIR)/zeus/k8s_ed25519 -o ProxyJump=$(HOST_USER)@$(ZEUS_IP) ubuntu@10.10.20.11

ssh-worker-3: ## SSH to worker-3 (jupiter)
	ssh -i $(SSH_DIR)/jupiter/k8s_ed25519 -o ProxyJump=$(HOST_USER)@$(JUPITER_IP) ubuntu@10.10.30.11

ssh-mars: ## SSH to mars bare-metal
	ssh $(HOST_USER)@$(MARS_IP)

ssh-zeus: ## SSH to zeus bare-metal
	ssh $(HOST_USER)@$(ZEUS_IP)

ssh-jupiter: ## SSH to jupiter bare-metal
	ssh $(HOST_USER)@$(JUPITER_IP)

kubectl: ## Run kubectl with kubeconfig
	kubectl --kubeconfig=files/kubeconfig $(ARGS)

grafana-tunnel: ## SSH tunnel to Grafana (http://localhost:3000)
	@echo "Grafana available at http://localhost:3000"
	ssh -L 3000:10.10.10.11:30300 -i $(SSH_DIR)/mars/k8s_ed25519 -N ubuntu@10.10.10.10

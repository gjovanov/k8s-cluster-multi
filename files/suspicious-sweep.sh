#!/bin/bash
# Comprehensive suspicious-service sweep. Designed to run on any of the
# cluster's hosts via SSH and produce a concise report.
set -uo pipefail

echo "=== HOST: $(hostname) ($(hostname -I | awk '{print $1}')) — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo

# Known-good shortlist for noise reduction
SYSTEM_RX='^(accounts-daemon|apparmor|apport|atd|cloud-config|cloud-final|cloud-init|cloud-init-local|console-setup|cron|dbus|docker|docker-restart-hook|e2scrub_all|fail2ban|finalrd|fwupd|grub|haproxy|haveged|host-firewall|host-firewall-reset|irqbalance|keyboard-setup|kmod|kubelet|containerd|libvirt|lvm2|lxd-agent|multipathd|networkd|networkd-dispatcher|ondemand|open-iscsi|open-vm-tools|plymouth|polkit|pollinate|qemu|rc-local|rpcbind|rsync|rsyslog|secureboot|setvtrgb|snap|ssh|systemd-|udev|ufw|unattended|user-runtime|vgauth|virt|wpa|getty|rescue|emergency|wg-|wg-fix-iptables|coturn-iptables|nginx|chrony|networking|netfilter|ua-|ubuntu-|e2scrub|cilium|dmesg|thermald|nanoclaw|clawui|oxmux-agent|audio-waveform|sni-proxy-update-docker-ips|auditd|listening-ports-audit|frps)\\.service'

EXPECTED_PORT_RX='^(22|53|67|80|443|3000|3080|3333|3478|4001|4010|4020|4030|4040|4050|4060|4070|4099|4200|4433|5000|5349|6379|6443|8088|8188|8443|8472|9000|9001|9100|9090|10250|10251|10252|10256|10257|10259|11434|2379|2380|3478|5349|10000|11000|12000|13000|30000|30030|30031|30040|30050|30080|30180|30300|30301|30443|30640|30880|31468|32767|51820|60000|60500|61000)$'

OLLAMA_KEYWORDS='ollama|frps|asterisk|frpc|ngrok|cloudflared|tailscale|wireguard-go|chisel|stunnel|socat|netcat\.openbsd|nc\.traditional|reverse-shell|cryptominer|xmrig|kthreadd-fake'

echo "── 1. Banned-keyword scan (binaries + processes) ──"
for path in /usr/local/bin /usr/bin /opt /root /tmp /var/tmp; do
  [[ ! -d "$path" ]] && continue
  found=$(sudo find "$path" -maxdepth 3 -type f -executable 2>/dev/null | grep -E "($OLLAMA_KEYWORDS)" 2>/dev/null | head -10)
  [[ -n "$found" ]] && echo "  [SUSPECT] $path: $found"
done
banned_proc=$(sudo pgrep -af "($OLLAMA_KEYWORDS)" 2>/dev/null | head -5)
[[ -n "$banned_proc" ]] && echo "  [SUSPECT] processes:" && echo "$banned_proc" | sed 's/^/    /'
[[ -z "$found$banned_proc" ]] && echo "  clean"

echo
echo "── 2. systemd unit files outside the system allow-list ──"
sudo systemctl list-unit-files --state=enabled --type=service --no-legend 2>/dev/null \
  | awk '{print $1}' \
  | grep -vE "$SYSTEM_RX" \
  | head -20 \
  | sed 's/^/  /' || echo "  none"

echo
echo "── 3. systemd timers (cron-equivalents) ──"
sudo systemctl list-timers --no-legend 2>/dev/null \
  | awk '{print $NF}' \
  | grep -vE "^(apt-daily|apt-daily-upgrade|dpkg-db-backup|e2scrub_all|fstrim|fwupd-refresh|logrotate|man-db|motd-news|sysstat-collect|sysstat-summary|systemd-tmpfiles-clean|ua-timer|update-notifier|sysstat-rotate|update-notifier-download|update-notifier-motd|anacron)\.timer$" \
  | head -10 \
  | sed 's/^/  /' || echo "  none"

echo
echo "── 4. Cron jobs (root + ${SUDO_USER:-${USER}}) ──"
sudo crontab -l 2>/dev/null | grep -vE "^#|^$" | head -10 | sed 's/^/  ROOT: /' || true
crontab -l 2>/dev/null | grep -vE "^#|^$" | head -10 | sed 's/^/  USER: /' || true
sudo ls /etc/cron.d/ 2>/dev/null | sed 's/^/  /etc\/cron.d\//' | head -10
[[ -z "$(sudo crontab -l 2>/dev/null | grep -vE '^#|^$')" ]] && [[ -z "$(crontab -l 2>/dev/null | grep -vE '^#|^$')" ]] && echo "  no user crontabs"

echo
echo "── 5. Listening ports (TCP) on non-loopback, non-VM-internal IPs ──"
sudo ss -tlnp 2>/dev/null \
  | awk 'NR>1 {print $4, $6}' \
  | grep -vE "^(127\\.|10\\.10\\.|10\\.244\\.|10\\.96\\.|10\\.111\\.|192\\.168\\.|::1|\\[::ffff:127)" \
  | awk '{split($1, a, ":"); print a[length(a)], $2}' \
  | sort -u \
  | head -30 \
  | while read port proc; do
      [[ -z "$port" ]] && continue
      if echo "$port" | grep -qE "$EXPECTED_PORT_RX"; then
        marker="[ok]"
      else
        marker="[?? ]"
      fi
      echo "  $marker $port  $proc"
    done

echo
echo "── 6. Recently-installed binaries in /usr/local/bin and /opt (mtime <90d) ──"
sudo find /usr/local/bin /usr/local/sbin /opt -type f -executable -mtime -90 2>/dev/null \
  | head -15 \
  | xargs -r ls -la 2>/dev/null \
  | awk '{print "  " $6, $7, $8, $NF}'

echo
echo "── 7. Active outbound connections to non-RFC1918 + non-cluster IPs ──"
sudo ss -tnp state established 2>/dev/null \
  | awk 'NR>1 {print $5, $7}' \
  | awk -F'[ :]' '$1 !~ /^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.|127\\.|::|fe80|0\\.0\\.0\\.0)/ {print "  " $0}' \
  | sort -u \
  | head -10 \
  | grep -v "^$" || echo "  none"

echo
echo "── 8. Users with active sessions ──"
who -u 2>/dev/null | head -10 | sed 's/^/  /'
last -F -n 5 2>/dev/null | head -7 | sed 's/^/  /'

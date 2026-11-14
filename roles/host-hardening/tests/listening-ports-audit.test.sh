#!/bin/bash
# The port audit against fixtures: no root, no real sockets, nothing but bash and awk.
#
#   bash roles/host-hardening/tests/listening-ports-audit.test.sh
#
# Each case pins a rule the audit cannot be allowed to lose. The two that matter most: a listener
# that is not on the list is always reported, and a run that could not list the sockets never
# reads as "nothing unexpected".
set -u
here=$(cd "$(dirname "$0")" && pwd)
template="$here/../templates/listening-ports-audit.sh.j2"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; for l in "$@"; do echo "       $l"; done; fails=$((fails + 1)); }

# render <tcp list> <udp list> <ephemeral processes>: the template with the lists a host would get.
render() {
  sed -e "s|^EXPECTED_TCP=.*|EXPECTED_TCP=\"$1\"|" \
      -e "s|^EXPECTED_UDP=.*|EXPECTED_UDP=\"$2\"|" \
      -e "s|^EPHEMERAL_UDP=.*|EPHEMERAL_UDP=\"$3\"|" \
      "$template" > "$work/audit.sh"
  if grep -q '{{' "$work/audit.sh"; then echo "FAIL: the template did not render"; exit 1; fi
  bash -n "$work/audit.sh" || { echo "FAIL: syntax"; exit 1; }
}

# run: the rendered audit over $work/tcp and $work/udp. Sets $rc, $out (stdout) and $prom (the file).
run() {
  mkdir -p "$work/out"
  out=$(LPA_OUT_DIR="$work/out" LPA_SS_TCP_FILE="$work/tcp" LPA_SS_UDP_FILE="$work/udp" \
        LPA_EPHEMERAL_RANGE="32768 60999" bash "$work/audit.sh" 2>&1)
  rc=$?
  prom="$work/out/host_unexpected_listener.prom"
}

tcp() { printf 'LISTEN 0      4096   %s   0.0.0.0:*    users:(("%s",pid=1234,fd=7))\n' "$1" "$2" >> "$work/tcp"; }
udp() { printf 'UNCONN 0      0      %s   0.0.0.0:*    users:(("%s",pid=1234,fd=7))\n' "$1" "$2" >> "$work/udp"; }
fresh() { : > "$work/tcp"; : > "$work/udp"; rm -rf "$work/out"; }
entries() { grep -c '^host_unexpected_listener{' "$prom"; }
has() { grep -q -F "$1" "$prom"; }

# 1. A listed port is silent; one that is not listed is reported, on the network.
fresh; render "22 443" "53" ""
tcp '0.0.0.0:22' sshd; tcp '0.0.0.0:443' nginx; tcp '0.0.0.0:27019' docker-proxy
run
if [ "$rc" = 0 ] && [ "$(entries)" = 1 ] && has 'host_unexpected_listener{proto="tcp",port="27019",process="docker-proxy",scope="network"} 1'; then
  ok "1  an unlisted listener is reported, a listed one is not"
else fail "1  an unlisted listener is reported, a listed one is not" "rc=$rc" "$(cat "$prom" 2>&1)"; fi

# 2. Bound to loopback only: recorded with its own scope and counted apart.
fresh; render "22" "" ""
tcp '127.0.0.1:5000' docker-proxy; tcp '[::1]:6010' sshd; tcp '127.0.0.53%lo:53' systemd-resolve; tcp '10.10.10.1:8080' python3
run
if [ "$(entries)" = 4 ] && has 'port="5000",process="docker-proxy",scope="loopback"' && has 'port="6010",process="sshd",scope="loopback"' \
   && has 'port="53",process="systemd-resolve",scope="loopback"' && has 'port="8080",process="python3",scope="network"' \
   && has 'host_port_audit_unexpected{scope="network"} 1' && has 'host_port_audit_unexpected{scope="loopback"} 3'; then
  ok "2  loopback-only sockets get scope loopback, anything else network"
else fail "2  loopback-only sockets get scope loopback, anything else network" "$(cat "$prom" 2>&1)"; fi

# 3. A range covers its two ends and nothing beyond them.
fresh; render "5900:5963" "21640:22415" ""
tcp '127.0.0.1:5899' qemu; tcp '127.0.0.1:5900' qemu; tcp '127.0.0.1:5963' qemu; tcp '127.0.0.1:5964' qemu
udp '0.0.0.0:21639' roomlerd; udp '0.0.0.0:21640' roomlerd; udp '0.0.0.0:22415' roomlerd; udp '0.0.0.0:22416' roomlerd
run
if [ "$(entries)" = 4 ] && has 'port="5899"' && has 'port="5964"' && has 'port="21639"' && has 'port="22416"'; then
  ok "3  a range covers both ends and nothing beyond"
else fail "3  a range covers both ends and nothing beyond" "$(cat "$prom" 2>&1)"; fi

# 4. One listener on IPv4 and on IPv6 is one line: a repeated series makes the whole file unreadable.
fresh; render "22" "" ""
tcp '0.0.0.0:6379' docker-proxy; tcp '[::]:6379' docker-proxy
run
if [ "$(entries)" = 1 ] && [ "$(sort "$prom" | uniq -d | grep -c '^host_')" = 0 ]; then
  ok "4  the same listener on two address families is reported once"
else fail "4  the same listener on two address families is reported once" "$(cat "$prom" 2>&1)"; fi

# 5. A named process may hold UDP sockets inside the ephemeral range, and only there, and only it.
fresh; render "" "53" "dnsmasq roomlerd"
udp '0.0.0.0:50077' dnsmasq; udp '0.0.0.0:32768' roomlerd; udp '0.0.0.0:60999' roomlerd
udp '0.0.0.0:32767' roomlerd; udp '0.0.0.0:61000' dnsmasq; udp '0.0.0.0:50078' nc
run
if [ "$(entries)" = 3 ] && has 'port="32767",process="roomlerd"' && has 'port="61000",process="dnsmasq"' && has 'port="50078",process="nc"'; then
  ok "5  the ephemeral allowance is per process and ends at the range"
else fail "5  the ephemeral allowance is per process and ends at the range" "$(cat "$prom" 2>&1)"; fi

# 6. The allowance is for UDP: the same process listening on TCP in that range is reported.
fresh; render "" "" "roomlerd"
tcp '0.0.0.0:47989' roomlerd
run
if [ "$(entries)" = 1 ] && has 'proto="tcp",port="47989",process="roomlerd",scope="network"'; then
  ok "6  no ephemeral allowance for a TCP listener"
else fail "6  no ephemeral allowance for a TCP listener" "$(cat "$prom" 2>&1)"; fi

# 7. A socket of the kernel has no process; it is reported as such unless listed.
fresh; render "" "51820" ""
printf 'UNCONN 0      0      0.0.0.0:51820   0.0.0.0:*\n' >> "$work/udp"
printf 'UNCONN 0      0      [::]:51820   [::]:*\n' >> "$work/udp"
printf 'UNCONN 0      0      0.0.0.0:8472   0.0.0.0:*\n' >> "$work/udp"
run
if [ "$(entries)" = 1 ] && has 'proto="udp",port="8472",process="kernel",scope="network"'; then
  ok "7  a socket without a process is named kernel"
else fail "7  a socket without a process is named kernel" "$(cat "$prom" 2>&1)"; fi

# 8. Every way ss writes an address: all interfaces, one interface, IPv6, a zone.
fresh; render "" "" ""
tcp '*:3080' bun; tcp '0.0.0.0%virbr1:67' dnsmasq; tcp '[::]:80' nginx; tcp '[fe80::1]%eth0:546' dhclient; tcp '[::ffff:127.0.0.1]:9000' java
run
if [ "$(entries)" = 5 ] && has 'port="3080",process="bun",scope="network"' && has 'port="67",process="dnsmasq",scope="network"' \
   && has 'port="80",process="nginx",scope="network"' && has 'port="546",process="dhclient",scope="network"' \
   && has 'port="9000",process="java",scope="loopback"'; then
  ok "8  every address form is read"
else fail "8  every address form is read" "$(cat "$prom" 2>&1)"; fi

# 9. A process picks its own name. Whatever it picks, the file stays one a collector can read.
fresh; render "" "" ""
printf 'LISTEN 0 128 0.0.0.0:4444 0.0.0.0:* users:(("ev\\il} 1\\nfake{x=",pid=1,fd=3))\n' >> "$work/tcp"
printf 'LISTEN 0 128 0.0.0.0:4445 0.0.0.0:* users:(("two words",pid=1,fd=3),("other",pid=2,fd=3))\n' >> "$work/tcp"
run
bad=$(grep -v '^#' "$prom" | grep -v -E '^host_unexpected_listener\{proto="(tcp|udp)",port="[0-9]+",process="[A-Za-z0-9._:@+-]+",scope="(network|loopback)"\} 1$' \
        | grep -v -E '^host_port_audit_unexpected\{scope="(network|loopback)"\} [0-9]+$' \
        | grep -v -E '^host_port_audit_last_run_timestamp_seconds [0-9]+$')
if [ "$(entries)" = 2 ] && [ -z "$bad" ] && has 'port="4445",process="two_words"'; then
  ok "9  a hostile process name cannot break the file"
else fail "9  a hostile process name cannot break the file" "unreadable lines: $bad" "$(cat "$prom" 2>&1)"; fi

# 10. Nothing listening at all is a result too: zero entries, both counts, a time, readable by others.
fresh; render "22" "53" ""
run
mode=$(stat -c %a "$prom" 2>/dev/null || stat -f %Lp "$prom" 2>/dev/null)
if [ "$rc" = 0 ] && [ "$(entries)" = 0 ] && has 'host_port_audit_unexpected{scope="network"} 0' && has 'host_port_audit_unexpected{scope="loopback"} 0' \
   && grep -q -E '^host_port_audit_last_run_timestamp_seconds [0-9]{10}$' "$prom" && [ "$mode" = 644 ] \
   && [ "$(ls -A "$work/out" | wc -l)" = 1 ]; then
  ok "10 an empty result is complete, mode 644, and leaves no temporary file"
else fail "10 an empty result is complete, mode 644, and leaves no temporary file" "rc=$rc mode=$mode files=$(ls -A "$work/out" | tr '\n' ' ')" "$(cat "$prom" 2>&1)"; fi

# 11. If the sockets cannot be listed, the run fails and the last good result stays as it was.
fresh; render "22" "" ""
tcp '0.0.0.0:9999' nc
run
before=$(cat "$prom")
rm -f "$work/tcp"
run
if [ "$rc" != 0 ] && [ "$(cat "$prom")" = "$before" ] && [ "$(ls -A "$work/out" | wc -l)" = 1 ]; then
  ok "11 a failed listing fails the run and keeps the last result"
else fail "11 a failed listing fails the run and keeps the last result" "rc=$rc" "$out" "$(cat "$prom" 2>&1)"; fi

# 12. The line the cron log keeps says how many, in both scopes.
fresh; render "22" "" ""
tcp '0.0.0.0:9999' nc; tcp '127.0.0.1:9998' nc; tcp '127.0.0.1:9997' nc
run
if [ "$out" = "audit complete; 1 unexpected on the network, 2 on loopback only" ]; then
  ok "12 the summary line counts both scopes"
else fail "12 the summary line counts both scopes" "$out"; fi

# 13. The value counts the runs in a row that saw the listener: the alert waits for the second.
#     One that left and came back starts again at 1, and a failed run in between keeps the count.
fresh; render "22" "" ""
again() { run; }   # same sockets, same output folder: the last result is the memory
tcp '0.0.0.0:9999' nc; tcp '0.0.0.0:9998' nc
run;   first="$(grep -c '} 1$' "$prom")"
again; second_a=$(grep -F 'port="9999"' "$prom" | awk '{print $2}'); second_b=$(grep -F 'port="9998"' "$prom" | awk '{print $2}')
mv "$work/tcp" "$work/tcp.keep"; again; rc_failed=$rc; mv "$work/tcp.keep" "$work/tcp"
after_failed=$(grep -F 'port="9999"' "$prom" | awk '{print $2}')
: > "$work/tcp"; tcp '0.0.0.0:9999' nc
again; third_a=$(grep -F 'port="9999"' "$prom" | awk '{print $2}'); third_b=$(grep -c -F 'port="9998"' "$prom")
tcp '0.0.0.0:9998' nc
again; fourth_a=$(grep -F 'port="9999"' "$prom" | awk '{print $2}'); fourth_b=$(grep -F 'port="9998"' "$prom" | awk '{print $2}')
if [ "$first" = 2 ] && [ "$second_a" = 2 ] && [ "$second_b" = 2 ] && [ "$rc_failed" != 0 ] && [ "$after_failed" = 2 ] \
   && [ "$third_a" = 3 ] && [ "$third_b" = 0 ] && [ "$fourth_a" = 4 ] && [ "$fourth_b" = 1 ]; then
  ok "13 the value counts consecutive sightings and starts over after an absence"
else fail "13 the value counts consecutive sightings and starts over after an absence" \
     "first=$first second=$second_a/$second_b failed-run rc=$rc_failed kept=$after_failed third=$third_a/$third_b fourth=$fourth_a/$fourth_b" "$(cat "$prom" 2>&1)"; fi

# 14. An entry may name the process a port belongs to. It covers the port, or the range, for that
#     process alone: the same port under another name is reported, and so is that process on the
#     next port. The name starts after the first @ and may itself hold an @ or a colon. The plain
#     entries beside it keep their meaning.
fresh; render "22 8080@caddy 9000@svc@1 9001@a:b" "53 5353@roomlerd 6000:6010@gamed 7000" ""
tcp '0.0.0.0:22' sshd; tcp '10.0.0.1:8080' caddy; tcp '10.0.0.2:8080' nginx; tcp '0.0.0.0:9000' 'svc@1'; tcp '0.0.0.0:9001' 'a:b'
udp '0.0.0.0:53' dnsmasq; udp '224.0.0.251:5353' roomlerd; udp '0.0.0.0:5353' avahi-daemon; udp '0.0.0.0:5354' roomlerd
udp '0.0.0.0:6000' gamed; udp '0.0.0.0:6010' gamed; udp '0.0.0.0:6011' gamed; udp '0.0.0.0:6005' other; udp '0.0.0.0:7000' nc
run
if [ "$rc" = 0 ] && [ "$(entries)" = 5 ] && has 'proto="tcp",port="8080",process="nginx"' && has 'proto="udp",port="5353",process="avahi-daemon"' \
   && has 'port="5354",process="roomlerd"' && has 'port="6011",process="gamed"' && has 'port="6005",process="other"'; then
  ok "14 an entry with @process covers the port for that process alone"
else fail "14 an entry with @process covers the port for that process alone" "rc=$rc" "$(cat "$prom" 2>&1)"; fi

# 15. The process is compared whole, and an entry written wrongly covers nothing: a name that is
#     only the beginning of the process's, one that is longer, an empty one, the two parts in the
#     wrong order.
fresh; render "" "5353@roomler 5354@roomlerd-helper 5355@ roomlerd@5356" ""
udp '0.0.0.0:5353' roomlerd; udp '0.0.0.0:5354' roomlerd; udp '0.0.0.0:5355' roomlerd; udp '0.0.0.0:5356' roomlerd
run
if [ "$(entries)" = 4 ] && has 'port="5353"' && has 'port="5354"' && has 'port="5355"' && has 'port="5356"'; then
  ok "15 the process is compared whole, and a malformed entry covers nothing"
else fail "15 the process is compared whole, and a malformed entry covers nothing" "$(cat "$prom" 2>&1)"; fi

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi

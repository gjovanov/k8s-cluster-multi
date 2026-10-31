#!/bin/bash
# The libvirt memory-guard hook against fixtures, no libvirt needed. Needs a Linux box: flock, stat -c.
#
#   bash roles/vmtest-host/tests/memory-guard.test.sh
#
# Each case pins a rule the hook cannot be allowed to lose, the first ones above all: a k8s VM is
# never refused, and nothing but a refused test guest ever exits non-zero, because libvirt kills a
# running guest when this script fails on `reconnect`.
set -u
here=$(cd "$(dirname "$0")" && pwd)
template="$here/../templates/libvirt-qemu-hook.sh.j2"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

GIB=1048576
hook="$work/hook"
# Render the template for a host whose ceiling is 116 GiB, with k8s-master-2 and k8s-worker-2.
sed -e "s/{{ ansible_managed }}/test/" \
    -e "s/{{ vmtest_hosts\[host_name\].ram_ceiling_mib }}/118784/g" \
    -e "s/{{ vms | selectattr.* }}/k8s-master-2 k8s-worker-2/" \
    -e "s/{{ vmtest_dir }}/\/nonexistent/" \
    "$template" >"$hook"
chmod +x "$hook"
if grep -q '{{' "$hook"; then echo "FAIL: the hook did not render"; exit 1; fi
bash -n "$hook" || { echo "FAIL: syntax"; exit 1; }

cat >"$work/choom" <<EOF
#!/bin/bash
echo "\$*" >>"$work/choom.log"
EOF
chmod +x "$work/choom"

export VM_GUARD_STATE_DIR="$work/run" VM_GUARD_CONFIG_DIR="$work/etc" VM_GUARD_HOLD_DIR="$work/holds"
export VM_GUARD_CHOOM="$work/choom" VM_GUARD_RESERVED_DIR="$work/reserved.d"

xml() { # <memory GiB> [currentMemory GiB]
  echo "<domain><memoryBacking/><memory unit='KiB'>$(($1 * GIB))</memory><currentMemory unit='KiB'>$((${2:-$1} * GIB))</currentMemory></domain>"
}

reset() { # k8s VMs defined and running at 8 and 64, nothing else
  rm -rf "$work/run" "$work/etc" "$work/holds" "$work/reserved.d" "$work/choom.log"
  mkdir -p "$work/run" "$work/etc" "$work/holds" "$work/reserved.d"
  xml 8 >"$work/etc/k8s-master-2.xml"
  xml 8 >"$work/run/k8s-master-2.xml"
  xml 64 >"$work/etc/k8s-worker-2.xml"
  xml 96 64 >"$work/run/k8s-worker-2.xml"
}

run() { # <guest> <op> <sub> <memory GiB> [currentMemory GiB]: sets $rc and $err
  err=$(xml "$4" "${5:-$4}" | "$hook" "$1" "$2" "$3" - 2>&1 >/dev/null)
  rc=$?
}

pass=0 failed=0
ok() { # <name> <condition...>
  local name="$1"
  shift
  if "$@"; then pass=$((pass + 1)); else failed=$((failed + 1)); echo "FAIL: $name (rc=$rc err=$err)"; fi
}
rc_is() { [ "$rc" = "$1" ]; }
said() { [[ "$err" == *"$1"* ]]; }
is_held() { [ -f "$work/holds/$1" ]; }
not_held() { [ ! -f "$work/holds/$1" ]; }

# ── Never refused, never fails ────────────────────────────────────────────────────────────────
reset
run k8s-worker-2 prepare begin 96
ok "a k8s VM starts whatever its size" rc_is 0

reset
rm -rf "$work/run" "$work/etc" "$work/holds"
run k8s-worker-2 prepare begin 96
ok "a k8s VM starts with nothing readable" rc_is 0
err=$(echo garbage | "$hook" k8s-master-2 prepare begin - 2>&1); rc=$?
ok "a k8s VM starts on XML that cannot be read" rc_is 0

for name in k8s-worker-2 some-guest; do
  for op in "reconnect begin" "attach begin" "started begin" "stopped end" "release end" "start begin" \
    "prepare end" "migrate begin" "restore begin" "whatever else"; do
    set -- $op
    rm -rf "$work/run" "$work/etc" "$work/holds"
    "$hook" "$name" "$1" "$2" - </dev/null >/dev/null 2>&1
    rc=$? err="$name $op"
    ok "exit 0 on $name $op, with nothing readable" rc_is 0
  done
done

rc=x err=x
"$hook" </dev/null >/dev/null 2>&1; rc=$?
ok "exit 0 when called with no arguments" rc_is 0

reset
"$hook" k8s-worker-2 reconnect begin - </dev/null >/dev/null 2>&1 &
pid=$!
wait $pid; rc=$?
ok "reconnect does not wait on stdin" rc_is 0

# ── oom_score_adj ─────────────────────────────────────────────────────────────────────────────
reset
echo 4242 >"$work/run/k8s-worker-2.pid"
echo 5353 >"$work/run/some-guest.pid"
"$hook" k8s-worker-2 started begin - </dev/null
"$hook" k8s-worker-2 reconnect begin - </dev/null
"$hook" some-guest started begin - </dev/null
rc=0 err="$(cat "$work/choom.log" 2>/dev/null | tr '\n' ';')"
ok "both start paths protect a k8s VM" test "$(grep -c -- '-p 4242 -n -900' "$work/choom.log")" = 2
ok "a test guest is left alone" test "$(grep -c 5353 "$work/choom.log")" = 0

# ── The allowance ─────────────────────────────────────────────────────────────────────────────
reset
run a prepare begin 44
ok "a guest that exactly fits starts" rc_is 0
ok "and holds its room" is_held a

reset
run a prepare begin 45
ok "one GiB over is refused" rc_is 1
ok "the refusal says why" said "needs 45 GiB"
ok "and gives the room left" said "of the 44 GiB"
ok "a refused guest holds nothing" not_held a

reset
xml 20 >"$work/run/running-1.xml"
xml 20 >"$work/run/running-2.xml"
run a prepare begin 5
ok "running guests count" rc_is 1
run a prepare begin 4
ok "and what is left is usable" rc_is 0

reset
xml 8 2 >"$work/run/ballooned.xml"
run a prepare begin 42
ok "a running guest counts at its balloon, as vmtest-audit reads it" rc_is 0

reset
run a prepare begin 45 2
ok "a guest asking to start counts at its full size" rc_is 1

reset
xml 96 >"$work/etc/k8s-worker-2.xml"
run a prepare begin 13
ok "a definition back at 96 shrinks the allowance to 12" rc_is 1
run a prepare begin 12
ok "and 12 still fits" rc_is 0

reset
xml 96 96 >"$work/run/k8s-worker-2.xml"
run a prepare begin 13
ok "a live VM at 96 with a smaller definition counts as 96" rc_is 1

reset
rm "$work/run/k8s-worker-2.xml"
run a prepare begin 45
ok "a stopped k8s VM keeps its room" rc_is 1

# ── A lane's reservation (reserved.d, shared with vmtest-audit) ───────────────────────────────
reset
echo 20480 >"$work/reserved.d/twin-lane"
run a prepare begin 25
ok "a reservation counts against others" rc_is 1
run a prepare begin 24
ok "and what is left is usable" rc_is 0

reset
echo 20480 >"$work/reserved.d/twin-lane"
xml 20 >"$work/run/twin-lane-1.xml"
run twin-lane-2 prepare begin 24
ok "a lane's own reservation is not held against its guests" rc_is 0
rm -f "$work/holds/twin-lane-2"
run twin-lane prepare begin 25
ok "that goes for a guest named after the lane, within the allowance" rc_is 1

reset
echo 20480 >"$work/reserved.d/twin"
run twin-lane-2 prepare begin 44
ok "a lane name is matched whole, up to a dash" rc_is 0
reset
echo 20480 >"$work/reserved.d/twin"
run twinning prepare begin 25
ok "never as a bare prefix" rc_is 1

reset
echo 20480 >"$work/reserved.d/crashed"
touch -d '13 hours ago' "$work/reserved.d/crashed"
run a prepare begin 44
ok "a reservation past 12 hours is a crashed lane's" rc_is 0

reset
rm -rf "$work/reserved.d"
run a prepare begin 44
ok "no reservation directory is fine" rc_is 0

# ── Fails closed, for test guests only ────────────────────────────────────────────────────────
reset
err=$(echo garbage | "$hook" a prepare begin - 2>&1 >/dev/null); rc=$?
ok "a guest whose size cannot be read is refused" rc_is 1

reset
rm "$work/etc/k8s-worker-2.xml"
run a prepare begin 1
ok "a k8s definition that cannot be read refuses a test guest" rc_is 1

reset
echo "<domain/>" >"$work/run/odd.xml"
run a prepare begin 1
ok "a running guest that cannot be sized refuses the next one" rc_is 1

# ── Restarting a guest ────────────────────────────────────────────────────────────────────────
reset
run lane release end 14
xml 14 >"$work/etc/lane.xml"
ok "a stopped guest keeps a hold" is_held lane
xml 44 >"$work/run/other.xml"
run lane prepare begin 14
ok "it restarts even with the room gone" rc_is 0

reset
run lane release end 14
xml 14 >"$work/etc/lane.xml"
run other prepare begin 31
ok "others cannot take the room it holds" rc_is 1
run other prepare begin 30
ok "and can take the rest" rc_is 0

reset
run lane release end 14
xml 14 >"$work/etc/lane.xml"
touch -d '31 minutes ago' "$work/holds/lane"
run other prepare begin 44
ok "a hold past its time frees the room" rc_is 0
ok "and is gone" not_held lane
xml 14 >"$work/run/x.xml"
run lane prepare begin 44
ok "a guest past its hold goes through the check again" rc_is 1

reset
run lane release end 14
touch -d '5 minutes ago' "$work/holds/lane"
run other prepare begin 44
ok "a torn down guest (no definition) frees its room" rc_is 0

reset
run lane release end 14
run other prepare begin 44
ok "a hold with no definition yet counts for two minutes (virt-install)" rc_is 1

reset
xml 14 >"$work/run/lane.xml"
echo $((14 * GIB)) >"$work/holds/lane"
run other prepare begin 30
ok "a running guest is not counted twice" rc_is 0

# ── Starts side by side ───────────────────────────────────────────────────────────────────────
reset
for i in 1 2 3 4 5 6 7 8; do
  (xml 10 | "$hook" "par$i" prepare begin - >/dev/null 2>&1; echo $? >"$work/par$i.rc") &
done
wait
started=$(cat "$work"/par*.rc | grep -c '^0$')
rc=0 err="$started of 8 started"
ok "eight 10 GiB guests at once: only four fit in 44" test "$started" = 4

echo "$pass passed, $failed failed"
[ "$failed" = 0 ]

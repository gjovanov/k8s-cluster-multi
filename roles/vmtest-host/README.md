# vmtest-host — throwaway install-test VM capability (FR-61)

Host-side half of the roomler install & verify matrix
([roomler-ai#1199](https://github.com/gjovanov/roomler-ai/issues/1199), spec
`roomler-ai/docs/fr/FR-61-vmtest-matrix.md`). The orchestrator and lanes live
in `roomler-ai-deploy/vmtest/` — this role only makes a bare-metal host able
to run the guests:

- packages: `qemu-system-arm` (aarch64 TCG for the ARM lane), `qemu-efi-aarch64`
  (AAVMF), `ovmf` (Win11 UEFI), `swtpm`/`swtpm-tools` (Win11 TPM2),
  `dosfstools`, `qemu-utils`, `genisoimage`
- `vmtest-net`: a second NAT network on **virbr2** (k8s-net keeps virbr1),
  plain DHCP pool — throwaway guests get random MACs and the orchestrator
  reads leases via `virsh domifaddr`
- `/var/lib/libvirt/vmtest/{iso,base,run}`: cached source images, golden
  images, per-run overlays — a sibling of, never inside, the k8s
  `/var/lib/libvirt/images` dir the maintenance docs say to never touch
- `/usr/local/bin/vmtest-audit`: the capacity preflight (`vmtest-audit
  [need_mib] [need_gb]`, non-zero exit = host cannot take the guest now)

Run it via `make vmtest-host` (or `vmtest-host-zeus` / `-mars`); it is
deliberately **not** in `site.yml`. `host-firewall` (itself opt-in/`never`)
now accepts both bridges, so a future re-enable will not strand vmtest guests
on DHCP — the 2026-05-01 foot-gun.

## Placement policy

- **zeus first** (pure compute), mars for overflow. **jupiter runs the prod
  storage node (mongodb/minio/roomler2 PVCs on k8s-worker-3) — only use it in
  an announced window.**
- **Sequential by default**: one guest per host at a time, ≤ 8 GiB / 4 vCPU.
  vCPUs are time-shared on KVM — only RAM is a hard commitment — so with
  sequential scheduling the k8s VMs should never need shrinking.
- **Count what is allocated, not what is free.** `vmtest-audit` refuses a guest
  unless every running guest at full size, plus the new one, plus a host reserve
  of about 9.3 GiB (`VMTEST_HOST_RESERVE_MIB`), fits in the host's RAM. On zeus
  that leaves 44 GiB for test guests in total. On 2026-10-31 at 21:34:41Z the kernel OOM-killed
  k8s-worker-2's qemu (97 GiB resident) and a production pod was down until
  21:50Z: guests were allocated well past the host's RAM, and the old check
  passed because it read only `MemAvailable`. A kit that boots its own guest
  instead of going through `vmtest.sh` must run `vmtest-audit` first.
- **A lane whose second guest boots late reserves it.** Put the MiB in a file
  under `/var/lib/libvirt/vmtest/reserved.d/<lane>` and remove it when the lane ends,
  so another session's audit doesn't read that room as spare. A file older than
  12 hours is treated as a crashed lane's and ignored. Name the lane's guests
  `<lane>` or `<lane>-<anything>`: the memory guard does not hold a lane's own
  reservation against them.

## Memory limits

A VM's memory is the host's for good once the guest has touched it: a guest's
page cache reads as used on the host, and the host cannot take it back. Over
months k8s-worker-2's guest filled 93 GiB that way, test guests held the rest of
zeus's 125, and at 21:34:41Z on 2026-10-31 the kernel killed the largest process
on the host. So the limit is on what VMs are ALLOCATED, never on what is free.

| zeus | GiB |
|---|---|
| Ceiling for all VMs (`vmtest_hosts.zeus.ram_ceiling_mib`) | 116 |
| k8s-master-2 | 8 |
| k8s-worker-2 | 64 |
| Test guests, all together | 44 |
| Left to the host | 9 |

Every pod on workers 2 and 3 at its limit comes to about 40 GiB, so 64 GiB holds
them all with room for page cache. The 96 GiB it had before was never workload.

`vmtest-audit` and a lane's own gate (`zeus-room.sh`) wait for room, but only a
kit that calls them gets that. **`/etc/libvirt/hooks/qemu`** is the part that
cannot be skipped, because libvirt runs it on every start:

- It refuses a test guest that would take the VMs past the ceiling, with a message
  saying so. It counts the k8s VMs, running test guests (`Used memory`, as the
  audit does), `reserved.d`, and the holds below.
- It never refuses a k8s VM, and decides that before it reads anything, so a
  recovery cannot depend on the guard working. A stopped k8s VM keeps its room.
- The allowance is not a number kept anywhere: it is the ceiling less the larger
  of what each k8s VM holds now and what its definition boots with. If worker-2
  ever came back at 96 GiB, test guests would simply get 12.
- A test guest that stopped keeps its room for 30 minutes and restarts without a
  check, so a lane's power-pull or clone-copy shutdown cannot lose it to someone
  else. The hold ends sooner if the guest is undefined.
- It sets `oom_score_adj` to -900 on the k8s VMs at every start and every libvirtd
  restart, so a shortage takes a test guest instead. That setting dies with the
  process, which is why it lives here.

The guard is installed where `ram_ceiling_mib` is set, so only on zeus today:

```bash
ansible-playbook playbooks/15-vmtest.yml --limit zeus --tags memory-guard
bash roles/vmtest-host/tests/memory-guard.test.sh   # on Linux, no libvirt needed
```

⚠ **libvirt caches whether a hook exists.** A hook that is new, or removed, needs
one `systemctl reload libvirtd`. A restart is not needed: the reload (SIGHUP) keeps
the daemon, every guest and every client connection, and fires no `reconnect`.
`iptables-save` shows the same rules afterwards, with the per-bridge blocks swapped
inside `LIBVIRT_*`. Editing the script needs neither. The role never reloads; do it
after the check below.

⚠ **Before a new hook or an edit lands where guests run, run it by hand for every
running guest, under the daemon's own profile:**
`sudo aa-exec -p libvirtd -- /etc/libvirt/hooks/qemu <guest> reconnect begin - </dev/null; echo $?`.
A libvirtd restart, which a package upgrade does on its own, fires `reconnect` for
every guest, and libvirt kills a running guest when the hook fails there. So: never
`set -e`, never a second non-zero exit, and never `virsh` in the script, which
deadlocks the daemon.

⚠ **Test a change through real libvirt too** (a throwaway `--paused` domain costs
nothing). libvirt fires `release end` after a refused `prepare`, for one, which no
fixture showed: it let a refused guest in on its second try until #3.

## Shrink runbook (only on a measured shortfall)

Run `vmtest-audit 8192 40` first. If — and only if — it FAILs on RAM:

1. Pick the donor: **zeus / k8s-worker-2** (jupiter only in a window; the
   masters at 8 GiB have no slack worth taking).
2. Drain is not required for a RAM-only shrink via the balloon, but check the
   node isn't the only Ready worker: `kubectl get nodes`.
3. Live-shrink (example: 96 GiB → 88 GiB). Leave out any of the three and the
   next VM restart quietly brings the old size back:

   ```bash
   virsh setmem k8s-worker-2 88G --live
   virsh setmaxmem k8s-worker-2 88G --config   # survives the next VM restart
   virsh setmem k8s-worker-2 88G --config
   ```

4. **Mirror the number in `inventory/group_vars/all.yml` `vms:`** (`memory:
   90112`) in the same change — that list is the only authoritative sizing
   (`inventory/hosts.yml` carries a drifting copy; update it too or delete the
   duplication while you're there).
5. Watch the guest for OOM pressure: `kubectl top nodes`, `dmesg` in the VM.
   Revert is the same three commands with the old size.

Until the VM next restarts, `Max memory` keeps the old size and `Used memory` is
the real one, which is what the audit and the guard read. The kubelet also goes on
reporting the old capacity until it restarts. Neither matters while pods are
nowhere near the new size, and neither is worth restarting anything for.

Disk cannot be shrunk in place (the qcow2 was sized at create) and vCPU shrink
is pointless — do not touch either.

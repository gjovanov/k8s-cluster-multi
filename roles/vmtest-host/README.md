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

## Shrink runbook (only on a measured shortfall)

Run `vmtest-audit 8192 40` first. If — and only if — it FAILs on RAM:

1. Pick the donor: **zeus / k8s-worker-2** (jupiter only in a window; the
   masters at 8 GiB have no slack worth taking).
2. Drain is not required for a RAM-only shrink via the balloon, but check the
   node isn't the only Ready worker: `kubectl get nodes`.
3. Live-shrink (example: 96 GiB → 88 GiB):

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

Disk cannot be shrunk in place (the qcow2 was sized at create) and vCPU shrink
is pointless — do not touch either.

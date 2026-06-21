# Host Disk Space: Thin-Provisioning Cleanup via qemu-img

**Host:** Windows desktop running VMware Workstation, 9 VMs provisioned via Vagrant + vagrant-vmware-desktop

## The problem

Host free disk space dropped from roughly 70GB to single digits over the course of
normal lab use, despite every VM's own guest filesystem usage being healthy
(16-32% used per `df -h` across the board, confirmed via a custom
`vm_disk_usage.sh` script). At its worst, the host hit 3GB free, which caused real
operational failures: `idx-1` and `idx-2` became unreachable over SSH and showed as
down in the Cluster Manager, ultimately requiring a full environment shutdown — and
that shutdown itself surfaced "Guest communication could not be established"
warnings from Vagrant for the two affected nodes, which turned out to be the
expected fallback to a forced power-off, not a separate new problem (Vagrant
couldn't SSH in to request a graceful shutdown because those nodes were already
unresponsive).

## Root cause

VMware Workstation's virtual disks are thin-provisioned: they grow as data is
written but **do not automatically shrink** when that data is later deleted inside
the guest. Comparing each VM's actual `.vmdk` file size on the host against its
guest-reported disk usage confirmed this directly — e.g. the elastic VM's `.vmdk`
was 33.56GB on the host while only ~21GB was actually in use inside the guest. This
gap was present across every VM in the lab, not isolated to one node. Confirmed via
PowerShell that no VMware snapshots were involved (no `.vmsn` files anywhere) — this
was purely a high-water-mark allocation issue, not hidden snapshot data.

The practical implication: tightening retention policies (Splunk's
`frozenTimePeriodInSecs`, Elastic's ILM) stops *future* growth, but does nothing to
reclaim space already consumed by data that's since been deleted. That space stays
allocated on the host until the virtual disk is explicitly compacted.

## What didn't work

Several standard approaches were tried and ruled out, in order:

1. **`vmware-toolbox-cmd disk shrink /`** (run inside the guest) — completes the
   zero-fill/wipe phase successfully (reaches 100%), but fails at the final
   host-side compaction step with `Error while shrinking: Shrinking not completed`.
   Confirmed this wasn't a free-space, disk-type, or isolation-flag issue (checked
   all three: disk type is `monolithicSparse` — growable, so shrink should be
   possible in principle; no `isolation.tools.diskShrink.disable` flag set in the
   `.vmx`; retried with much more host headroom and it still failed). Best working
   theory: `vagrant-vmware-desktop` drives VMs through its own helper service
   rather than VMware's standard `hostd` process, and the final guest-to-host RPC
   that requests disk compaction likely isn't properly relayed through that layer.
2. **`vmware-vdiskmanager.exe`** — not present at all on this VMware Workstation
   installation; recent Workstation Pro releases dropped the standalone CLI tool in
   favor of GUI-only compaction.
3. **VMware Workstation GUI → Compact** — unusable for these specific VMs, because
   `vagrant-vmware-desktop` doesn't register VMs into Workstation's normal
   inventory/library. They're simply invisible to the GUI.
4. Confirmed via a public Vagrant GitHub issue that the `vmware_desktop` provider
   itself has documented, explicit "Shrinking disks is not supported" behavior —
   this is a known gap in the tooling combination, not something specific to this
   lab's configuration.

## What worked: qemu-img convert

`qemu-img` operates directly on the `.vmdk` file and sidesteps all of the broken
RPC/plumbing above entirely, since it doesn't depend on VMware Tools, vagrant's
helper service, or the Workstation GUI at all.

**Why zero-filling guest free space first is essential:** a sparse vmdk only
tracks which blocks have *ever* been written, not which ones the guest currently
considers deleted/free. Skipping the zero-fill step would cause `qemu-img` to
faithfully copy over all that stale-but-still-allocated data, producing a
compacted file barely smaller than the original — defeating the purpose.

**Tooling:** `qemu-img` was run from WSL (`sudo apt install qemu-utils`) rather
than hunting for a standalone Windows binary of uncertain provenance — operating
on the `.vmdk` via its `/mnt/c/...` path.

### The repeatable procedure (per VM)

1. Boot the VM (if not already up), SSH in, zero-fill free space:
   ```bash
   sudo dd if=/dev/zero of=/zerofile bs=1M; sync; sudo rm -f /zerofile
   ```
   The `dd` command is *expected* to end in `No space left on device` — that's the
   correct termination condition for this technique, not an error.
2. Cleanly shut the VM down (`vagrant halt <name>`).
3. From WSL, in the VM's `vmware_desktop/<uuid>/` directory:
   ```bash
   qemu-img convert -O vmdk -o subformat=monolithicSparse,compat6 -p \
     generic-ubuntu2204-vmware.vmdk generic-ubuntu2204-vmware-compacted.vmdk
   ```
   `subformat=monolithicSparse,compat6` keeps the output in the same format the
   source already uses, maximizing compatibility with VMware Workstation reading
   it back.
4. Sanity-check the result before touching anything:
   ```bash
   qemu-img info generic-ubuntu2204-vmware-compacted.vmdk
   ```
5. Swap in, keeping the original as a safety net rather than overwriting in place:
   ```bash
   mv generic-ubuntu2204-vmware.vmdk generic-ubuntu2204-vmware-ORIGINAL-BACKUP.vmdk
   mv generic-ubuntu2204-vmware-compacted.vmdk generic-ubuntu2204-vmware.vmdk
   ```
6. Boot the VM and confirm it's genuinely healthy — not just that it boots, but
   that the actual services on that node are running normally (Splunk's own
   `splunk status` / `cluster-status` / `shcluster-status` for Splunk nodes,
   `systemctl status elasticsearch kibana` for the elastic node, relevant service
   checks for obs and uf-1).
7. Only once confirmed healthy, delete the backup to actually reclaim the host
   space:
   ```bash
   rm generic-ubuntu2204-vmware-ORIGINAL-BACKUP.vmdk
   ```

### Special handling for idx-1 / idx-2

These two were the nodes that had actually crashed and been hard-powered-off
during the original disk crisis. Before including them in this compaction
process, they were booted and verified independently first — confirming clean
journal recovery and a fully healthy cluster (`splunk show cluster-status
-verbose` from the Cluster Manager, checking for searchable peers and no lingering
fixup tasks) — as a separate concern from the disk work itself, given the
indexer cluster's RF=2 replication meant either peer's data could in principle
have been recoverable from the other if anything had been inconsistent.

### Per-VM results

| VM | Original `.vmdk` size | After compaction |
|---|---|---|
| obs | 9.55GB | ~9.0GB (smallest gain — confirms it had little phantom space to begin with) |
| uf-1 | 11.6GB | ~9.5GB |
| mgmt-2 | 21.18GB | completed successfully |
| mgmt-1 | 27.12GB | completed successfully |
| sh-1 | 25.12GB | completed successfully |
| sh-2 | 25.35GB | completed successfully |
| idx-1 | 29.38GB | completed successfully (post cluster health verification) |
| idx-2 | 29.07GB | completed successfully (post cluster health verification) |
| elastic | 33.56GB | completed successfully (largest file, longest conversion time) |

*(Exact post-compaction sizes for everything past uf-1 weren't individually logged
during the session — worth filling in if useful for future reference.)*

## General lesson

When a hypervisor's standard tooling (vendor GUI, vendor CLI) fails for a VM
that's managed by an intermediary layer like Vagrant, a format-level tool that
operates directly on the underlying disk file — rather than going through
whatever orchestration/RPC layer is actually broken — is a reliable way to
sidestep the problem entirely. Worth remembering this pattern for other
Vagrant/VMware quirks, not just disk shrinking specifically.
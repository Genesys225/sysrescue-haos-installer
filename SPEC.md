# Spec: HAOS Installer USB

## Assumptions

Stated up front so they can be shot down before they cost anything:

1. Targets are **UEFI-capable x86-64** machines. Legacy BIOS/CSM targets are refused, not worked around.
2. The stick is built **once per SystemRescue release** and re-used across many target machines.
3. The operator is physically at the target machine with a keyboard. Nothing runs headless or unattended.
4. No network at install time — not at boot, not during the write. First boot of HAOS itself still needs Ethernet + internet, which is HAOS's requirement, not ours.
5. The target's existing contents are expendable. The tool's job is to make that destruction deliberate, not to prevent it.
6. One HAOS version per stick.

## Objective

A reusable USB stick that boots a bare x86-64 machine into a live environment and writes Home Assistant OS onto **that machine's internal disk**, with the image carried on the stick and a human confirming before anything is destroyed.

**Why this exists.** HAOS running *from* a USB stick is the failure mode being retired. Installing to internal NVMe/SATA removes a class of problems — slow random I/O, flash wear under a database workload, and a boot device that can be knocked out of its socket.

> **Correction (Task 3).** This section originally offered the 64 GB Kingston as proof of that thesis — "a corpse of that pattern" — citing an empty `docker/` directory and `lost+found` "populated" on both writable partitions. Two errors, recorded so neither is repeated:
>
> 1. **`lost+found` was not populated.** ext4 preallocates it to roughly 16 KB at mkfs time; that is its normal *empty* size, not evidence of an fsck recovery. What remains — `docker/` and `supervisor/homeassistant/` both empty — is equally consistent with an install that was simply never used.
> 2. **The stick is not dead.** Mid-task it reported `detected capacity change from 120913920 to 0` after its filesystems were unmounted, and that was called a failed flash controller here. It was a stale device node. A replug re-enumerated it at the full 61.9 GB with all eight partitions intact and mounting read-write.
>
> The rationale for installing to internal storage stands on general grounds. This stick was never evidence for it, and a confident hardware verdict was drawn from a single kernel line.

**Who it's for.** The operator standing at the target machine. Assumed competent with a boot menu; assumed to know nothing about that machine's disk layout, which is why the tool shows its work before it writes.

**Success looks like:** walk up to a bare box, boot the stick, pick a disk from a list, type the device path to confirm, wait, reboot into HA onboarding. No second computer, no internet, no per-machine image flashing.

### Non-goals (v1)

- Preseeding HAOS network/Wi-Fi config via the HAOS `CONFIG` partition
- Restoring an HA backup as part of install
- Supporting legacy BIOS/CSM targets
- Installing SystemRescue itself to the target
- Any unattended / auto-select mode

## Tech Stack

| Component | Choice | Version / note |
|---|---|---|
| Live base | SystemRescue x86-64 | **13.02** (2026‑08‑01, kernel 6.18.41) |
| Payload | `haos_generic-x86-64-*.img.xz` | **18.2** (2026‑07‑30, 552.5 MB) |
| Script language | bash | as shipped in SystemRescue (Arch-based) |
| Prompts | plain `read` | no TUI dependency — see Open Questions #1 |
| Customization | drop-in files on the FAT32 root | `autorun` + `sysrescue.d/*.yaml` |
| Test harness | QEMU + OVMF | UEFI firmware required to exercise the real path |

### Two constraints that drive the whole design

**The stick must be writable.** Image-copying the SystemRescue ISO byte-for-byte produces a read-only ISO9660 medium, which kills the drop-in premise entirely. The stick is created with **`sysrescueusbwriter`** (Linux, AppImage) or **Rufus in ISO mode** (Windows), both of which yield writable FAT32.

> **The two `dd`s — do not conflate them.** This project both bans and requires `dd`, in different places:
>
> | Context | Verdict |
> |---|---|
> | Creating the SystemRescue stick | **Banned.** Read-only medium → drop-ins impossible → design fails |
> | Writing HAOS to the target disk | **Required.** `xzcat … \| dd of=/dev/nvme0n1` *is* the install |
>
> Rule of thumb: `dd` never touches the stick, and is the only thing that touches the target.

**The write is streamed: `xzcat … | dd`.** Only the 552 MB compressed file ever lives on the stick; the expanded image is never materialised anywhere.

> **Correction (Task 1).** This was originally justified by FAT32's 4 GB per-file ceiling, on the assumption that the expanded image would exceed it. Measured: the HAOS 18.2 generic x86-64 image is **1 962 954 752 bytes (1.83 GiB)** uncompressed — comfortably *under* the cap. It would fit as a file. Streaming is still correct, but for a weaker reason: it avoids a pointless 1.83 GiB intermediate write to slow flash, and keeps the stick's contents to one file per HAOS version. This is a preference, not a hard constraint, and should not be defended as one.

The volume label must match the release (`RESCUE1302`) or the stick won't boot. A SystemRescue bump is a full stick rewrite; a HAOS bump is a file swap.

**Measured artifact sizes** (Task 1): SystemRescue ISO **1.3 GB**, HAOS image **552 MB** compressed / **1.83 GiB** expanded. Roughly 1.9 GB of stick space in use.

## Commands

**Build the stick** (from this workstation):

```bash
# 1. Fetch and measure the artifacts (idempotent, resumable)
./build/fetch-artifacts.sh
./tests/run.sh                     # proves they are present and intact

# 2. Create a WRITABLE stick — never by image-copying the ISO
curl -LO https://fastly-cdn.system-rescue.org/download/usbwriter/1.1.1/sysrescueusbwriter-x86_64.AppImage
chmod 755 sysrescueusbwriter-x86_64.AppImage
./sysrescueusbwriter-x86_64.AppImage tmp/systemrescue-13.02-amd64.iso
#   text-UI: lists USB devices, you pick one; self-escalates via sudo/pkexec/su
#   result: FAT32, label RESCUE1302, writable

# 3. Drop in the payload
./build/make-stick.sh /media/$USER/RESCUE1302
```

Versions and URLs live in **`build/artifacts.conf`** and nowhere else — the fetch script, the tests, and the stick builder all read from it, so a version bump is a one-line edit. The volume label is derived from the version there so the two cannot drift apart.

**Lint:** `shellcheck -S style src/autorun build/*.sh tests/*.sh`

**Test (QEMU, nothing real at risk):**

```bash
./tests/qemu-boot.sh --iso tmp/systemrescue-13.02-amd64.iso   # bare ISO
./tests/qemu-boot.sh --stick /dev/sdb                          # the real stick
./tests/qemu-boot.sh --legacy --iso ...                        # negative test
./tests/qemu-boot.sh --iso ... --screenshot tmp/boot.ppm       # headless evidence
```

The harness discovers OVMF itself, copies a **private** `OVMF_VARS` into `tmp/` so the root-owned system copy is never mutated, and deliberately skips the `secboot`/`ms` firmware variants — HAOS requires Secure Boot off, so testing against Secure Boot firmware would validate a configuration we do not support. `--stick` accepts **removable devices only**; there is no override flag, because this project's entire purpose is writing raw images to block devices.

**Unit tests:** `./tests/run.sh`

## Project Structure

```
sysrescue-haos-installer/
├── SPEC.md                  this document
├── CLAUDE.md                project rules; names tmp/ as the scratchpad
├── src/
│   ├── autorun              the installer — SystemRescue executes this by name
│   └── 500-haos.yaml        boot config drop-in
├── build/
│   └── make-stick.sh        copies drop-ins + payload onto a prepared stick
├── tests/
│   ├── run.sh               unit runner
│   └── fixtures/lsblk-*     captured lsblk output for selection-logic tests
├── tasks/                   plan.md + todo.md (created at Plan phase)
└── tmp/                     scratchpad — gitignored, never committed
```

**Stick layout as booted:**

```
/run/archiso/bootmnt/        (FAT32, label RESCUE1302)
├── autorun                  ← src/autorun
├── sysrescue.d/
│   └── 500-haos.yaml        ← src/500-haos.yaml
├── haos/
│   ├── haos_generic-x86-64-18.2.img.xz
│   └── haos_generic-x86-64-18.2.img.xz.sha256
├── logs/                    install-<UTC>-<target>.log, one per run
└── sysresccd/ EFI/ boot/    SystemRescue's own files — untouched
```

## Code Style

One snippet beats a paragraph. This is the destructive core, and it sets the conventions:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

readonly BOOTMNT=/run/archiso/bootmnt
readonly LOGDIR="${BOOTMNT}/logs"

die()  { printf '\n[FATAL] %s\n' "$*" >&2; exit 1; }
note() { printf '[*] %s\n' "$*"; }

require_uefi() {
  [[ -d /sys/firmware/efi ]] || die \
    "Booted in legacy BIOS/CSM mode. HAOS requires UEFI — installing now would
     produce a machine that cannot boot what we just wrote. Reboot, enable UEFI
     boot and disable Secure Boot in firmware setup, then run this again."
}

confirm_target() {
  local dev="$1"
  printf '\n  About to ERASE %s — %s, %s\n\n' \
    "$dev" "$(lsblk -dno SIZE "$dev")" "$(lsblk -dno MODEL "$dev")"
  lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev"
  printf '\n  Everything above is destroyed. Type the device path exactly to confirm: '

  local answer
  read -r answer
  [[ "$answer" == "$dev" ]] || die "Confirmation did not match. Nothing was written."
}
```

Conventions, in force everywhere:

- `set -Eeuo pipefail` at the top of every script
- `[[ ]]` always, `[ ]` never; every expansion quoted
- Functions are verbs; constants are `readonly`
- **Every destructive operation goes through one funnel function.** There is exactly one place in the codebase that writes to a block device.
- Error messages tell the operator *what to do*, not just what broke. A `die()` string that doesn't contain a next action is a bug.

## Behaviour

1. **Preflight** — each failure is a hard stop with remediation text:
   - UEFI present (`/sys/firmware/efi`)
   - `/run/archiso/bootmnt` mounted
   - exactly one `haos/*.img.xz` present
   - sha256 matches the sidecar file (catches stick rot, which is the expected failure mode for a stick that lives in a drawer)
2. **Enumerate candidates** — `lsblk -dpno NAME,SIZE,MODEL,TRAN,RM,TYPE`; keep `TYPE=disk`; drop `RM=1`, `TRAN=usb`, the boot device, and loop/zram/rom. Sub-32 GB disks are warned about, not excluded.
3. **Present** — numbered list with size, model, transport, plus each disk's existing partitions and labels, so the operator can recognise "that one is Windows". Zero candidates is a hard stop explaining why.
4. **Confirm** — operator types the full device path. A bare `y` is not accepted. Anything else aborts having written nothing. **Never auto-select, even when there is exactly one candidate.**
5. **Write** — `xzcat "$img" | dd of="$dev" bs=4M conv=fsync oflag=direct status=progress`
6. **Verify** — re-stream and byte-compare over the image's uncompressed length (from `xz --robot --list`), so the comparison ends at the image boundary rather than tripping over the larger disk.
7. **Settle** — `sync`, `partprobe`, then print the resulting table; `hassos-boot` and friends should now be visible.
8. **Report** — write the run log to the stick, print next steps: remove the USB, first boot needs Ethernet and internet, then `http://homeassistant.local:8123`.
9. **Offer** reboot or poweroff. Never automatic.

## Testing Strategy

| Level | Covers | Mechanism |
|---|---|---|
| Static | script correctness | `shellcheck -S style` clean, zero suppressions |
| Unit | candidate selection + filtering | source the functions, inject captured `lsblk` fixtures; assert boot device, USB and removable disks are all excluded |
| Negative | every preflight guard | legacy-BIOS QEMU boot must refuse; corrupted sha256 must refuse; mistyped confirmation must leave the target byte-identical |
| Integration | the real write path | QEMU + OVMF, real stick passed through, virtio target; assert the target boots to HA onboarding |
| Hardware | the actual artifact | the disposable 64 GB Kingston + a real machine |

Coverage expectation: **every `die()` path in preflight has a negative test.** The write path is proven by booting the result in QEMU, not by mocking `dd` — a mocked `dd` proves nothing about a tool whose entire job is `dd`.

## Boundaries

**Always**
- Verify the sha256 before writing
- Require UEFI before writing
- Require a typed device path, never a `y/n`
- Log every run to the stick
- Stream the image; never materialise a decompressed file on FAT32

**Ask first**
- Bumping SystemRescue (forces a stick rewrite and a label change)
- Introducing any network dependency at install time
- Adding a HAOS config/network preseed
- Widening target selection to include removable media

**Never**
- Write to a removable device, a USB device, or the boot medium
- Auto-select a target, under any circumstances
- Continue past a failed checksum
- Build the stick with `dd` (read-only medium, drop-ins impossible)
- Reboot the target without the operator asking for it

## Success Criteria

1. Stick built from clean SystemRescue 13.02 + three drop-ins boots on UEFI hardware.
2. On boot, autorun reaches the selection prompt with zero operator input.
3. Legacy BIOS boot refuses to write and exits non-zero.
4. A deliberately corrupted payload refuses to write.
5. A mistyped confirmation leaves the target disk byte-identical (verified by pre/post hash of the first 100 MB).
6. Happy path: target shows `hassos-boot` / `hassos-data` after the write, verification passes, machine boots to HA onboarding.
7. The run log is on the stick and readable after removal.
8. A second run on the same stick behaves identically — no leftover state.

## Open Questions

1. **Does SystemRescue 13.02 ship `dialog`?** Spec assumes plain `read` to avoid the dependency. Confirm at build; if `dialog` is present, it's a cosmetic upgrade, not a design change.
2. ~~**Does HA publish an upstream checksum for `img.xz`?**~~ **Answered: no.** The 18.2 release carries 35 assets and not one is a digest. The sidecar is self-generated at fetch time, so it detects corruption and stick rot but does **not** authenticate the download — the only integrity guarantee on the HAOS image is TLS to GitHub at fetch time. Worth weighing before this stick touches a client machine.
3. **Multiple HAOS versions per stick** — capacity allows it easily. v1 deliberately fails if more than one image is present. Revisit if it turns out to matter.

**Resolved:** the stick writer is `sysrescueusbwriter-x86_64.AppImage` v1.1.1, not the legacy `usb_inst.sh`. Verify the label it produces is `RESCUE1302` before dropping files in — the label is a boot requirement, not cosmetic.

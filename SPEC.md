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

**Why this exists.** HAOS running *from* a USB stick is the failure mode being retired. The 64 GB Kingston earmarked as the test medium is itself a corpse of that pattern: HAOS installed 2025‑06‑25, and by 2026‑07‑01 the docker directory was empty, both writable partitions had populated `lost+found`, and nothing was recoverable. Flash wear on a stick under HAOS's write load is not survivable long-term. Installing to internal NVMe/SATA removes the failure mode.

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

**The stick must be writable.** `dd`-ing the SystemRescue ISO produces a read-only ISO9660 medium, which kills the drop-in premise entirely. The stick is created with SystemRescue's USB writer (Linux) or **Rufus in ISO mode** (Windows), both of which yield FAT32.

**FAT32 caps a single file at 4 GB.** This is independent of stick capacity — a 64 GB stick does not help. The expanded HAOS image can therefore never exist as a file on the stick, so the write is always a stream: `xzcat … | dd`. Only the 552 MB compressed file lives on FAT32.

A third, smaller one: the volume label must match the release (`RESCUE1302`) or the stick won't boot. A SystemRescue bump is a full stick rewrite; a HAOS bump is a file swap.

## Commands

**Build the stick** (from this workstation):

```bash
# 1. Fetch SystemRescue and verify against the published checksum
curl -LO https://sourceforge.net/projects/systemrescuecd/files/sysresccd-x86/13.02/systemrescue-13.02-amd64.iso
sha256sum -c systemrescue-13.02-amd64.iso.sha256

# 2. Create a WRITABLE stick — never dd
sudo mount -o loop,ro systemrescue-13.02-amd64.iso /mnt/iso
sudo /mnt/iso/usb_inst.sh          # interactive; select the target stick

# 3. Drop in the payload
./build/make-stick.sh /media/$USER/RESCUE1302
```

**Fetch the HAOS payload:**

```bash
curl -L -o tmp/haos_generic-x86-64-18.2.img.xz \
  https://github.com/home-assistant/operating-system/releases/download/18.2/haos_generic-x86-64-18.2.img.xz
sha256sum tmp/haos_generic-x86-64-18.2.img.xz > tmp/haos_generic-x86-64-18.2.img.xz.sha256
```

**Lint:** `shellcheck -S style src/autorun build/make-stick.sh`

**Test (QEMU, nothing real at risk):**

```bash
qemu-img create -f qcow2 tmp/target.qcow2 64G
cp /usr/share/OVMF/OVMF_VARS_4M.fd tmp/OVMF_VARS.fd
sudo qemu-system-x86_64 -enable-kvm -m 4096 -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=tmp/OVMF_VARS.fd \
  -device qemu-xhci \
  -drive file=/dev/sdb,format=raw,if=none,id=stick -device usb-storage,drive=stick \
  -drive file=tmp/target.qcow2,format=qcow2,if=virtio \
  -boot menu=on
```

**Negative test (legacy BIOS):** same command with both `pflash` lines removed — the script must refuse to write.

**Unit tests:** `./tests/run.sh`

## Project Structure

```
haos-usb-installer/
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
2. **Does HA publish an upstream checksum for `img.xz`?** If not, the sidecar is self-generated at build time — which still catches stick rot but does not authenticate the download. Worth resolving before trusting the stick to a client machine.
3. **Is the USB writer on the ISO named `usb_inst.sh`?** Verify when the ISO is first mounted; the command in Build assumes it.
4. **Multiple HAOS versions per stick** — capacity allows it easily. v1 deliberately fails if more than one image is present. Revisit if it turns out to matter.

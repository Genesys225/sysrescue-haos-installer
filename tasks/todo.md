# Tasks: HAOS Installer USB

Ordered by dependency. See [plan.md](plan.md) for strategy and risks.

**Who runs what:** every task below is code-and-test work except the physical steps — writing the Kingston with `sysrescueusbwriter` (Task 3) and the hardware validation (Task 10). Those touch real storage on real machines and are **operator-run**; the deliverable from this side is the exact command.

---

- [ ] **Task 1: Acquire and verify artifacts**
  - Fetch SystemRescue 13.02 ISO, verify against the published sha256. Fetch HAOS 18.2 `img.xz`, generate the sidecar checksum, and record the uncompressed length via `xz --robot --list` (Task 7's verification needs that number).
  - Acceptance: both artifacts in `tmp/`, ISO checksum verified against upstream, HAOS sidecar generated, uncompressed byte count recorded.
  - Verify: `sha256sum -c` passes for both; `xz -l` reports a plausible size.
  - Files: `tmp/` only (gitignored — artifacts are never committed)

- [ ] **Task 2: QEMU/OVMF harness**
  - Locate this workstation's OVMF firmware (package and path vary), then write a harness that creates a fresh qcow2 target, copies a private `OVMF_VARS`, and boots a given stick source. Takes `--stick /dev/sdb` or `--stick-image tmp/stick.img`, plus `--legacy` to drop the pflash lines for the negative test.
  - Acceptance: harness boots the plain SystemRescue ISO to its boot menu in UEFI mode; `--legacy` boots without UEFI.
  - Verify: run it against the bare ISO — SystemRescue menu appears; `/sys/firmware/efi` exists in the booted system and does not under `--legacy`.
  - Files: `tests/qemu-boot.sh`

- [ ] **Task 3: Walking skeleton — prove the drop-in mechanism** ⛳ CHECKPOINT
  - `make-stick.sh` creates `haos/`, `sysrescue.d/`, `logs/` on a prepared stick and copies in the drop-ins plus payload. `500-haos.yaml` sets the `autorun` scope to run without waiting (`ar_nowait`, `wait: never`, `on_error: break`) and leaves the GUI off. `autorun` at this stage only prints a banner and dumps three facts: whether `/sys/firmware/efi` exists, what `/run/archiso/bootmnt` contains, and its own permission bits.
  - **Deliberately not setting `copytoram`** — the stick must stay mounted so Task 8 can write logs back to it.
  - Acceptance: the banner appears on console with zero operator input.
  - Verify: boot in QEMU. If it does not run, read the permission bits from the dump — a missing exec bit means FAT32 stripped it, and the fix is `shell: true` in the autorun scope.
  - **Stop here.** If the mechanism does not work and `shell: true` does not rescue it, the SystemRescue base choice reopens and the rest of this plan is void.
  - Files: `build/make-stick.sh`, `src/500-haos.yaml`, `src/autorun`

- [ ] **Task 4: Preflight guards**
  - Implement `require_uefi`, `require_bootmnt`, `require_single_image`, `require_checksum`. Each exits non-zero with a message naming the operator's next action.
  - Acceptance: all four fire correctly; no guard message describes only the failure without a remedy.
  - Verify: `--legacy` boot refuses to proceed; a corrupted sidecar refuses; a second `.img.xz` on the stick refuses; running `src/autorun` on the workstation exits at the bootmnt guard without enumerating anything.
  - Files: `src/autorun`, `tests/run.sh`

- [ ] **Task 5: Candidate enumeration and filtering**
  - `list_candidates()` over `lsblk -dpno NAME,SIZE,MODEL,TRAN,RM,TYPE`: keep `TYPE=disk`; drop `RM=1`, `TRAN=usb`, loop/zram/rom, and the boot device. Boot device resolves via `findmnt -no SOURCE /run/archiso/bootmnt` → partition → parent disk.
  - Acceptance: against the captured workstation fixture, the USB stick and every loop device are excluded and the four NVMe/SATA disks remain; against the QEMU fixture, only the virtio target remains.
  - Verify: `./tests/run.sh` — pure unit tests, no hardware.
  - Files: `src/autorun`, `tests/fixtures/lsblk-*`, `tests/run.sh`

- [ ] **Task 6: Selection and typed confirmation** (still non-destructive)
  - Numbered menu showing size, model, transport, and each disk's existing partitions and labels. Zero candidates is a hard stop. Never auto-select, including when exactly one candidate exists. `confirm_target` requires the exact device path.
  - The write function is a **stub that prints what it would do** — nothing is destructive until Task 7.
  - Acceptance: a mistyped confirmation exits non-zero and the stub is never reached; a correct one reaches the stub.
  - Verify: QEMU run exercising both paths; `shellcheck -S style` clean.
  - Files: `src/autorun`

- [ ] **Task 7: Streamed write and verification** ⛳ CHECKPOINT
  - Replace the stub: `xzcat "$img" | dd of="$dev" bs=4M conv=fsync oflag=direct status=progress`, retrying once without `oflag=direct` and logging the downgrade if the device rejects it. Then verify by re-streaming and comparing over the recorded uncompressed length, so the comparison stops at the image boundary instead of running into the larger disk.
  - This is the only function in the codebase that writes to a block device.
  - Acceptance: the QEMU target shows `hassos-boot` and `hassos-data` afterwards; verification passes; flipping a byte on the target makes verification fail.
  - Verify: `lsblk` on the target image; deliberate corruption test.
  - Files: `src/autorun`

- [ ] **Task 8: Settle, log, report, offer reboot**
  - `sync` and `partprobe`, print the resulting partition table, tee the whole run to `logs/install-<UTC>-<target>.log` on the stick, then print next steps: remove the USB, first boot needs Ethernet and internet, reach `http://homeassistant.local:8123`. Offer reboot or poweroff with neither as default.
  - Acceptance: the log survives stick removal and is readable from the workstation; nothing reboots on its own.
  - Verify: run in QEMU, then mount the stick image and read the log.
  - Files: `src/autorun`

- [ ] **Task 9: End-to-end integration**
  - Full unattended-to-the-prompt run in QEMU, then boot the written target standalone under OVMF with user-mode networking (HAOS needs internet on first boot to pull Core) and confirm onboarding is reachable. Then run the whole thing a second time on the same stick.
  - Acceptance: all eight Success Criteria in SPEC.md pass; the second run behaves identically to the first.
  - Verify: reach the onboarding page from the host; diff the two run logs for unexpected divergence.
  - Files: `tests/qemu-boot.sh`, possibly `tests/integration.md` for the manual steps

- [ ] **Task 10: Hardware validation** — operator-run
  - Write the disposable Kingston with `sysrescueusbwriter`, drop in the payload, boot a real machine, install to its internal disk.
  - Acceptance: the real machine boots HAOS from internal storage and reaches onboarding, with the USB removed.
  - Verify: manual, at the machine.
  - Files: none — this validates, it doesn't produce

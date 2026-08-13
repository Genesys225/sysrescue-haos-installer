# Tasks: HAOS Installer USB

Ordered by dependency. See [plan.md](plan.md) for strategy and risks.

**Who runs what:** every task below is code-and-test work except the physical steps — writing the Kingston with `sysrescueusbwriter` (Task 3) and the hardware validation (Task 10). Those touch real storage on real machines and are **operator-run**; the deliverable from this side is the exact command.

---

- [x] **Task 1: Acquire and verify artifacts** — done. ISO verified against upstream sha256; HAOS sidecar self-generated (upstream publishes none); uncompressed length measured at 1 962 954 752 bytes. Test suite `tests/run.sh` — 10 assertions, all green.
  - Fetch SystemRescue 13.02 ISO, verify against the published sha256. Fetch HAOS 18.2 `img.xz`, generate the sidecar checksum, and record the uncompressed length via `xz --robot --list` (Task 7's verification needs that number).
  - Acceptance: both artifacts in `tmp/`, ISO checksum verified against upstream, HAOS sidecar generated, uncompressed byte count recorded.
  - Verify: `sha256sum -c` passes for both; `xz -l` reports a plausible size.
  - Files: `tmp/` only (gitignored — artifacts are never committed)

- [x] **Task 2: QEMU/OVMF harness** — done. Firmware found at `/usr/share/OVMF/OVMF_CODE_4M.fd`; KVM usable via ACL (`user:gene:rw-`), QEMU 8.2.2. Both modes boot SystemRescue 13.02 to an autologin root shell inside 45 s — evidence in `tmp/boot-uefi.png` and `tmp/boot-legacy.png`. 20 assertions green, shellcheck clean.
  - **Acceptance partially deferred, by necessity.** The written criterion was that `/sys/firmware/efi` exists under UEFI and not under `--legacy`. That cannot be checked from outside the guest, and both modes render an identical console, so a screenshot cannot distinguish them. Confirming it requires running a command *inside* the guest — which is exactly what Task 3's skeleton does, and its spec already calls for dumping whether `/sys/firmware/efi` exists. **The firmware-mode assertion is therefore verified in Task 3, not here.** What Task 2 proves is that the harness assembles a correct command line and that both modes boot.
  - Files: `tests/qemu-boot.sh`, `tests/test-qemu-harness.sh`

- [x] **Task 3: Walking skeleton — prove the drop-in mechanism** ⛳ CHECKPOINT — **PASSED on hardware** (laptop, 2026‑07‑23 per that machine's clock, which runs ~3 weeks slow). Evidence recovered from the stick at `logs/sysrescue-autorun.log`.
  - `Using autorun scripts from /run/archiso/bootmnt/autorun` → `executing 1000-autorun` → our banner → `Execution of 1000-autorun returned 0`. Zero operator input.
  - **The FAT32 exec-bit risk never existed.** SystemRescue does not execute the script in place: it copies it to `/var/autorun/tmp/autorun`, runs it there at mode `755`, then deletes it. The filesystem's inability to store an exec bit is irrelevant by construction. `shell: true` and `sysrescue-customize` are not needed — the whole escalation ladder is moot.
  - **Boot medium is mounted read-only:** `vfat ro,relatime,fmask=0022,...`. The skeleton's write probe caught it, and the report could not be written. `mount -o remount,rw /run/archiso/bootmnt` was verified working on that hardware — **Task 8 must remount before logging.**
  - **That laptop booted legacy BIOS/CSM, not UEFI.** Task 4's `require_uefi` will correctly refuse to install on it as configured. Its firmware needs changing before Task 10.
  - Discharges half of Task 2's deferred assertion: firmware-mode detection is now confirmed from inside a guest, for the legacy case. The UEFI case is proven in QEMU but not yet from inside.
  - Files: `build/make-stick.sh`, `src/500-haos.yaml`, `src/autorun`
  - `make-stick.sh` creates `haos/`, `sysrescue.d/`, `logs/` on a prepared stick and copies in the drop-ins plus payload. `500-haos.yaml` sets the `autorun` scope to run without waiting (`ar_nowait`, `wait: never`, `on_error: break`) and leaves the GUI off. `autorun` at this stage only prints a banner and dumps three facts: whether `/sys/firmware/efi` exists, what `/run/archiso/bootmnt` contains, and its own permission bits.
  - **Deliberately not setting `copytoram`** — the stick must stay mounted so Task 8 can write logs back to it.
  - Acceptance: the banner appears on console with zero operator input.
  - Verify: boot in QEMU. If it does not run, read the permission bits from the dump — a missing exec bit means FAT32 stripped it, and the fix is `shell: true` in the autorun scope.
  - **Stop here.** Escalation order if it does not run: `shell: true` in the autorun scope, then `sysrescue-customize` with the same files in `iso_add/` (costs a build step, keeps the design — see [prior-art.md](../docs/prior-art.md)). The base choice only reopens if all three fail.
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
  - **Must `mount -o remount,rw /run/archiso/bootmnt` first** — Task 3 established the boot medium is mounted read-only, and the remount was verified working on real hardware. Without it the log silently fails to write.
  - `sync` and `partprobe`, print the resulting partition table, tee the whole run to `logs/install-<UTC>-<target>.log` on the stick, then print next steps: remove the USB, first boot needs Ethernet and internet, reach `http://homeassistant.local:8123`. Offer reboot or poweroff with neither as default.
  - Log filenames must not assume a correct clock: the test laptop's was three weeks slow. Include the target device in the name so runs stay distinguishable regardless.
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

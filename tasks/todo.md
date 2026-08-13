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

- [x] **Task 4: Preflight guards** — code complete. All four implemented and covered by 22 assertions in `tests/test-preflight.sh`, each checked for both the refusal and its remediation text. Corrupt checksum, missing sidecar, zero images, two images, legacy boot, and absent boot medium all refuse. Running `src/autorun` on the workstation stops at the bootmnt guard without listing anything.
  - **Boot-level check closed, on hardware.** `require_uefi` refused on the legacy-booting laptop; the operator used the remediation text to locate the machine's UEFI boot setting, changed it, and the next boot passed preflight. Both branches exercised on real hardware, and the acceptance criterion — that a refusal names an action, not just a fault — was met in the strongest available way: someone acted on it without further help.
  - Two Task 3 behaviours were removed here, deliberately: writing a report file to the boot medium (impossible on a read-only mount; Task 8 owns logging after a remount) and `mkdir -p` on the boot medium path (a side effect that created a directory a later test needed absent).
  - Files: `src/autorun`, `tests/test-preflight.sh`, `tests/test-skeleton.sh`

- [x] **Task 5: Candidate enumeration and filtering** — done. 16 assertions over five captured fixtures; also verified against this workstation's live device list (45 loop devices and the USB stick excluded, five real disks kept, model strings with spaces intact).
  - **Parsing uses lsblk's `--pairs` format, not columns.** The plan specified `-dpno`, which is columnar. That misreads real machines: `MODEL` contains spaces (`EXAMPLE SATA SSD 960G`) and `TRAN` is empty for loop and virtio devices, so fields shift silently. Silent misparsing in the code that decides which disk to erase is not an acceptable failure mode, so the format changed.
  - Undersized disks are deliberately **kept**. A 16 GB eMMC is a poor host for HAOS, but hiding the only disk in a machine is worse than warning about it — and the operator still has to confirm.
  - An unresolvable boot device yields an empty exclusion rather than a guessed one: excluding nothing is recoverable, excluding the wrong thing is not.
  - Files: `src/autorun`, `tests/test-enumerate.sh`, `tests/fixtures/lsblk-*.txt`

- [x] **Task 6: Selection and typed confirmation** — done, still non-destructive. 22 assertions in `tests/test-selection.sh`. Menu shows size, model, transport and each disk's existing partitions; zero candidates is a hard stop that explains why; a single candidate is still presented as a menu rather than assumed.
  - Every rejection path is asserted to leave the stub unreached: bare `y`, another disk's path, an empty answer, and menu inputs `0`, `99`, `abc`, empty.
  - Blank entries are filtered out of the candidate array. An empty string there would render as a menu row with no device *and* match an empty confirmation — the one input an operator can produce by pressing Return twice.
  - Two test-harness bugs found and fixed here, both of the kind that make a suite pass while testing nothing: stub functions referencing `$2` were reading their own arguments rather than the script's, and an empty candidate list was being emitted as one blank line, so the zero-candidate case never occurred.
  - Files: `src/autorun`, `tests/test-selection.sh`

- [ ] **Task 7: Streamed write and verification** ⛳ CHECKPOINT
  - ⚠️ **Before writing a single line of this task, neutralise the unit suite.** `tests/test-selection.sh` drives `run_selection` to completion, typing the confirmation, against candidate paths like `/dev/nvme0n1` — the disk holding `/` on this workstation. That is safe only while `write_image` is a stub; the moment it is real, running the suite would `dd` here. The unit harness must stub `write_image` itself.
  - **The real write is exercised in QEMU, not locally.** The Task 2 harness gives a qcow2 target on a virtio bus, so an actual `dd` inside the guest destroys nothing, and the whole path — boot, preflight, menu, typed confirmation, write — runs as the operator would experience it. The result can then be booted to prove it worked, which a loopback file cannot show.
  - Two layers, two reasons: the unit suite is stubbed because it runs on the workstation; the integration test is real because it runs sandboxed.
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

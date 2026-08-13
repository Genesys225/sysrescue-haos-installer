# Implementation Plan: HAOS Installer USB

Derived from [SPEC.md](../SPEC.md). Ten tasks, strictly ordered by dependency.

## Strategy

**Retire the biggest unknown first, with the least code.**

The entire design rests on one unproven assumption: *that a drop-in `autorun` file on a writable FAT32 SystemRescue stick actually executes on boot.* Everything else — enumeration, confirmation, streaming, verification — is ordinary shell scripting that can be written and unit-tested on the workstation. If the drop-in mechanism doesn't fire, none of it matters and the base choice has to be revisited.

So Task 3 is a **walking skeleton**: a stick whose `autorun` prints one line and exits. It costs almost nothing and it proves or kills the premise before a single line of real installer logic exists.

There is a specific reason to doubt the mechanism: **FAT32 cannot store a POSIX executable bit.** SystemRescue must be compensating somewhere — a mount umask, or the autorun runner invoking the interpreter explicitly. Whether that compensation exists is unknown to us, and the skeleton is what answers it. If the exec bit turns out to be the blocker, the `shell: true` key in the `autorun` YAML scope is the intended escape hatch.

**A drop-in failure is not fatal to the design.** Per [prior-art.md](../docs/prior-art.md), `sysrescue-customize` bakes the same two files into a custom ISO via its `iso_add/` stage, needing only `xorriso` and `mksquashfs`. So the worst case at Task 3 is that we acquire a build step, not that we lose the base. Drop-in remains first choice because upstream names the writable-stick method as recommended, and because it keeps a HAOS version bump down to swapping one file.

## Dependency graph

```
1. Acquire artifacts ──┬──> 2. QEMU/OVMF harness ──┐
                       │                            ├──> 3. Walking skeleton ──> 4. Preflight
                       └────────────────────────────┘                                  │
                                                                                        v
   9. Integration <── 8. Report + log <── 7. Write + verify <── 6. Select/confirm <── 5. Enumerate
          │
          v
   10. Hardware validation
```

Tasks 5 and 6 are pure logic and can be written in parallel with 4 if convenient; everything else is sequential.

## Development safety

All development targets a **qcow2 file in QEMU**. No task before #10 touches physical storage other than the disposable Kingston stick, and even that is only ever written *as a stick*, never as an install target.

The workstation itself is protected structurally rather than by care: the installer hard-fails when `/run/archiso/bootmnt` is absent (Task 4). Since that path only exists inside the live environment, accidentally executing `src/autorun` on the workstation exits before it can enumerate anything — and the workstation's NVMe drives, which hold `/` and `/boot/efi`, are never candidates. This preflight guard is a correctness requirement *and* the dev safety net; it is written before any code that can write to a block device (Task 7).

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| ~~FAT32 exec bit blocks `autorun`~~ | **Resolved — never a risk** | SystemRescue copies the script to `/var/autorun/tmp/` and runs it there at 755. It never executes from the stick, so the filesystem's permission model is irrelevant. Neither fallback is needed. |
| Boot medium mounted read-only | **Confirmed real** | Found by Task 3's write probe: `vfat ro,relatime`. `remount,rw` works; Task 8 must do it before logging |
| QEMU USB passthrough of the physical stick is flaky or permission-bound | Medium | Image the stick to a file (`dd if=/dev/sdb of=tmp/stick.img` — read-only on the stick) and attach the file instead |
| OVMF firmware path/package differs on this workstation | High | Resolved in Task 2 before anything depends on it; paths recorded in `tests/qemu-boot.sh` |
| `oflag=direct` unsupported on some target devices | Low | Detect write failure and retry once without `oflag=direct`, logging the downgrade |
| Writer produces a label other than `RESCUE1302` | Low | Task 1 verifies the label; wrong label means the stick will not boot at all, so it fails loudly |
| SystemRescue lacks `dialog` | Low | Spec already assumes plain `read`; no dependency to break |

## Verification checkpoints

Three points where work stops until something is proven:

- **After Task 3** — the drop-in mechanism is confirmed working, or we fall back to a baked ISO via `sysrescue-customize` and absorb a build step.
- **After Task 7** — a QEMU target disk carries a bootable HAOS, verified byte-for-byte.
- **After Task 9** — a virtual machine reaches HA onboarding unattended-to-the-prompt.

## Task list

Full detail in [todo.md](todo.md). Summary:

| # | Task | Produces |
|---|---|---|
| 1 | Acquire and verify artifacts | `tmp/` ISO + image + checksums |
| 2 | QEMU/OVMF harness | `tests/qemu-boot.sh` |
| 3 | Walking skeleton — prove drop-in autorun runs | `build/make-stick.sh`, `src/500-haos.yaml`, trivial `src/autorun` |
| 4 | Preflight guards | `src/autorun` preflight + negative tests |
| 5 | Candidate enumeration and filtering | enumeration functions + `tests/fixtures/lsblk-*` |
| 6 | Selection and typed confirmation | interactive flow, still non-destructive |
| 7 | Streamed write and verification | the one function that writes to a block device |
| 8 | Settle, log to stick, report, offer reboot | completion path |
| 9 | End-to-end integration in QEMU | green integration run |
| 10 | Hardware validation | a real machine booting HAOS |

## Out of scope for this plan

Everything in SPEC.md's Non-goals, plus: no CI (the test suite needs a UEFI-capable VM host and a physical stick, which no runner has), and no packaging or distribution of the stick image.

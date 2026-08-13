# Integration test

The unit suite proves the logic. This proves the artifact. Both are needed:
a green suite says the code does what it was told, and only a boot says the
stick installs a working system.

Run it after any change to `src/autorun`, `src/500-haos.yaml`, or the
artifact versions in `build/artifacts.conf`.

## Prerequisites

- `qemu-system-x86_64`, `qemu-img`, `ovmf` installed
- `/dev/kvm` readable (an ACL entry is enough; group membership is not needed)
- Read access to the stick device. It is `root:disk`, so either grant a
  temporary ACL — `sudo setfacl -m u:$USER:rw /dev/sdb` — or run the harness
  under `sudo`. The ACL disappears when the stick is unplugged.

## Rule: never mount the stick on the host while a guest has it

QEMU is given the raw device. If the host also has a partition from that
device mounted, two independent writers with separate caches share one FAT32
filesystem and nothing coordinates them. Unmount before booting a guest:

```bash
udisksctl unmount -b /dev/sdb1
```

This bit us once already, and the recovery cost more time than the test.

## Stage 1 — install, inside a guest

```bash
./build/make-stick.sh /media/$USER/RESCUE1302   # stick must be current
udisksctl unmount -b /dev/sdb1
qemu-img create -f qcow2 tmp/target.qcow2 64G
./tests/qemu-boot.sh --stick /dev/sdb
```

Drive it as an operator would: choose the disk, type its path to confirm.
`/dev/vda` is the virtual target; the stick appears as USB and is correctly
absent from the menu.

Expect, in order: the autorun banner, `preflight passed`, the disk menu, the
confirmation prompt, a progress-reporting write, and
`Verification passed — /dev/vda matches the image exactly.`

To run it unattended, keystrokes can be injected through the QEMU monitor —
see `tmp/drive-qemu.sh` from the Task 7 run for the pattern. That is scratch,
not a supported entry point.

**Recover the evidence** by mounting the stick afterwards and reading
`logs/install-<target>-<timestamp>-<host>-<pid>.log`. The run writes it by
remounting the read-only boot medium, so its presence also proves the logging
path works on real media.

## Stage 2 — boot what was installed

```bash
cp /usr/share/OVMF/OVMF_VARS_4M.fd tmp/OVMF_VARS_installed.fd
qemu-system-x86_64 -machine q35 -m 4096 -enable-kvm -cpu host \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=tmp/OVMF_VARS_installed.fd \
  -drive file=tmp/target.qcow2,format=qcow2,if=virtio \
  -netdev user,id=n0,hostfwd=tcp::18123-:8123 \
  -device virtio-net-pci,netdev=n0
```

No stick attached — the disk must boot on its own, which is the entire point
of installing rather than running from USB.

Networking matters here: Home Assistant downloads its core on first start and
cannot finish setup without internet. `hostfwd` exposes the guest's 8123 on
the host's 18123 because `homeassistant.local` relies on mDNS, which does not
survive user-mode NAT.

First boot is slow — several minutes of downloading with an idle-looking
console.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:18123
```

`200` means onboarding is reachable and the install is genuinely complete.

## Stage 3 — idempotence

Run stage 1 again on the same stick, against a freshly created target. The
second run must behave identically. Compare the two logs; the only expected
differences are timestamps, pid, and throughput figures.

## What this cannot prove

Hardware-specific behaviour: real firmware quirks, and `oflag=direct` against
a physical NVMe rather than a virtio disk. Those need Task 10, on the laptop.

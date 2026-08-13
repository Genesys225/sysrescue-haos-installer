# Prior Art

Checked before building, because reusing a working tool beats writing one. Conclusion: three projects do roughly this, none is dependable, and none uses the drop-in approach.

## The three projects

| Project | Base | Activity | Verdict |
|---|---|---|---|
| [JosephM101/hass-os-installer-iso](https://github.com/JosephM101/hass-os-installer-iso) | Debian bookworm via `live-build`, Python wizard | **0 stars, 0 forks, 0 releases**, last commit 2026‑04‑15, license `NOASSERTION` | Closest in shape. Unusable as a dependency |
| [Xalies/HAOS-USB-Creator](https://github.com/Xalies/HAOS-USB-Creator) | Alpine payload, **C# Windows GUI** builder | 4 stars, v0.5.0 (2026‑05‑27), AGPL‑3.0 | Most alive. Builder is Windows-only |
| [freshautomations/home-assistant](https://github.com/freshautomations/home-assistant) | Debian installer ISO | **Dead since 2023‑02‑16**, 3 stars | Also installs *Supervised*, not HAOS — different product |

Details that matter:

- **JosephM101** bundles the HAOS image offline, lists disks, and requires the operator to confirm **twice** before writing. Its default target is HAOS **12.4** against today's 18.2. The author's own roadmap calls the build process "janky" and states that consistent autonomous builds are not yet possible — which is why there are no release artifacts and you must run `live-build` yourself.
- **Xalies** downloads the latest HAOS at *stick-creation* time and bakes it on for offline install. It has both an interactive mode and an unattended mode, the latter restricted to firing only when exactly one internal drive is detected. The catch is structural: the thing that builds the stick is a C# Windows application, so on a Linux workstation the build step is unavailable.
- **freshautomations** is three and a half years stale and solves a different problem.

## What this confirms

Three people independently converged on the same design, which is reassuring about the shape:

- **HAOS ships no installer.** The image must be block-copied to the target disk by something. Everyone has to build this.
- **Bake the image offline.** All three do.
- **UEFI/amd64 only.** Matches our decision to hard-fail on legacy BIOS rather than accommodate it.
- **Interactive selection with confirmation.** JosephM101 double-confirms; we require a typed device path, which is the same instinct expressed differently.

## Where we diverge, and why it's the point

**Every one of them rebuilds an ISO or ships a builder application.** None customizes a stock live system in place. The consequence is that each carries a build toolchain as a hard prerequisite:

| Project | Prerequisite to produce a stick |
|---|---|
| JosephM101 | `live-build` + `just`, or Vagrant + VirtualBox |
| Xalies | Windows + the C# app |
| Ours | Official USB writer, then copy three files |

That is the whole justification for not adopting one of them. Our build step is `sysrescueusbwriter` followed by a file copy — no build system, no container, no cross-platform dance, and a HAOS version bump is swapping one file on the stick rather than rebuilding an image.

**One deliberate divergence to note:** Xalies will auto-select the target when exactly one internal drive exists. SPEC.md forbids auto-selection under all circumstances. That is a considered difference, not an oversight — recorded here so it doesn't get "fixed" later by someone who assumes it was.

## SystemRescue's own deployment surface

The manual documents more automation hooks than we're using:

- **autorun** — run scripts at startup *(we use this)*
- **YAML configuration** with `global`, `autorun`, `gui_autostart`, `autoterminal`, `sysconfig` scopes *(we use this)*
- **autoterminal** — run programs on specific virtual terminals
- **GUI autostart** — for graphical-desktop launches
- **sysrescue-customize** — rebuild an ISO with your files baked in
- **SRM (SystemRescue Modules)** — ship custom files or extra packages as a loadable module
- **PXE network booting** — deploy over the network with no stick at all

### sysrescue-customize is our fallback, and it de-risks the plan

`sysrescue-customize` unpacks, modifies, and rebuilds an ISO from a recipe directory with four stages applied in order:

```
iso_delete/            files to remove from the ISO
iso_add/               files to copy in — including sysrescue.d/*.yaml and autorun
iso_patch_and_script/  patches and scripts, alphabetical
build_into_srm/        content packed into a SystemRescue Module
```

It needs only `xorriso` and `mksquashfs`, and it is a plain bash script that runs on most Linux distributions — not Arch-only.

This matters for Task 3. The plan's biggest checkpoint is "does a drop-in `autorun` actually execute from FAT32, given that FAT32 cannot store an executable bit?" The previous framing was that a failure there voids the plan and reopens the base choice. That was too pessimistic: `sysrescue-customize` bakes the *same two files* into a custom ISO via `iso_add/`, so a drop-in failure costs us a build step, not the design. The upstream docs still name the writable-stick method as recommended, so drop-in stays the first choice.

## Recorded, not proposed

**PXE booting** would remove the stick from the process entirely for fleet deployment — boot the target over the network, same autorun, no physical media to carry or lose. That's a guess about where this could go if it ever serves more than one machine at a time. Out of scope for v1 and not acted on.

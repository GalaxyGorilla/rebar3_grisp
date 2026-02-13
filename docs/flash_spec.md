# GRiSP2 eMMC flashing (recovery + provisioning) – design note

This document captures *why* we want a GRiSP2 flashing workflow, what a good
CLI/UX should look like, and the key technical constraints to respect.

It is intentionally short: enough to guide implementation and user-facing docs
without overspecifying internals.

## Motivation (user value)

We want GRiSP2 users to be able to:

1) **Recover a board** when it no longer boots
- e.g. broken bootloader / broken system partitions / bad release
- requirement: must work even if the current on-device software is unusable

2) **Provision / automate** flashing in labs or manufacturing
- repeatable, scriptable flashing from a host
- minimal manual steps; predictable artifacts

The common requirement is an entry point that does not depend on the currently
installed software. On i.MX-based GRiSP2 this means starting from **ROM Serial
Downloader mode** (BOOT_MODE pins/jumpers + power-cycle).

## User experience / CLI goals

### Primary command

`rebar3 grisp flash`

Design goals:
- **One obvious command** for the common case.
- **Safe default**: do the least destructive operation that yields a bootable
  system.
- **Scriptable**: provide `--yes` and machine-friendly output.
- **Preflight**: allow validation without hardware (`--dry-run`).
- **Diagnostics**: allow verifying that the recovery loader is actually running
  without writing to eMMC (`--probe`).

### Proposed modes

- Default (safer):
  - flash **system partition A** only

- `--bootloader` (destructive):
  - flash a **full eMMC image** (boot + partitions + system)

- `--probe` (no writes):
  - boot the temporary recovery loader and run read-only diagnostics

- `--dry-run` (no hardware):
  - generate/validate the artifacts and the flash bundle, but do not touch USB

### Options

- `--relname`, `--relvsn` – select release
- `--yes` – skip confirmation
- `--flash_loader <path>` – override bundled loader image

## Technical circumstances (reality and constraints)

### Upstream recovery path (baseline)

Upstream GRiSP2 toolchain documentation describes recovery via **`imx_uart`**:
- upload a barebox image in Serial Downloader mode
- then use barebox to write an eMMC image

This is the *known-supported* recovery mechanism and must be referenced in docs.

Source: https://github.com/grisp/grisp2-rtems-toolchain#recovery

### `uuu`-based workflow status

This plugin work implements a **ROM → temporary loader → fastboot** approach
using NXP `uuu` bundles.

Important: treat `uuu` on GRiSP2 as **experimental until proven on real
hardware**.

If GRiSP2 recovery ultimately requires `imx_uart`, we can still keep the same
high-level UX (`rebar3 grisp flash`) while changing the transport under the hood
(or adding a backend selector).

### Flash loader

A recovery flow needs a temporary loader that:
- boots from ROM download
- exposes a mechanism to write/query eMMC

Current implementation bundles a U-Boot-based loader:
- `priv/flash/flash_loader.bin`
- build documentation: `docs/flash_loader.md`

### Artifact generation and deploy coupling

Flashing relies on firmware artifacts built by `rebar3 grisp firmware`.
That path may invoke `rebar3 grisp deploy --tar` to produce a bundle.

For flashing/provisioning flows, deploy must support a **tarball-only** mode:
- no copy destination required
- no copy pre/post scripts

(Implemented in this fork.)

## Related documentation (where to point users)

- `rebar3 grisp flash --help`
- `docs/flash_loader.md` (how the bundled loader is built)
- GRiSP2 recovery baseline (imx_uart):
  https://github.com/grisp/grisp2-rtems-toolchain#recovery

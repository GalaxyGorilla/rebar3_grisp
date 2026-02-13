# GRiSP2 flashing notes (rebar3_grisp)

Small design note for GRiSP2 recovery/provisioning.

## Motivation

Enable flashing GRiSP2 eMMC for:
- **recovery** (board does not boot)
- **provisioning automation**

## Reality check: upstream recovery does *not* use `uuu`

The upstream GRiSP2 toolchain documentation describes recovery via **`imx_uart`**
(uploading a barebox image over the ROM serial download interface), then writing
an eMMC image from the resulting barebox shell.

So a `uuu`-based workflow should be treated as **experimental** until proven on
real GRiSP2 hardware.

Source: https://github.com/grisp/grisp2-rtems-toolchain#recovery

## Proposed CLI (current implementation direction)

`rebar3 grisp flash`
- default: flash system partition A (safer)
- `--bootloader`: flash full eMMC image (destructive)
- `--probe`: boot loader and print debug info (no eMMC writes)
- `--dry-run`: prepare artifacts + bundle, but do not perform the actual flash

Implementation currently assumes a ROM → temporary loader → fastboot workflow.

## Tarball-only deploy decoupling

Firmware generation uses `rebar3 grisp deploy --tar` internally to create a
release bundle. For flashing/provisioning flows, deploy should support a
**tarball-only** mode that does not require a copy destination or scripts.

(Implemented in this fork.)

# GRiSP2 recovery / provisioning flashing – motivation + pathways

This note is about **user value** and **technical pathways** for flashing GRiSP2
from a host in a recovery/provisioning context. It intentionally avoids locking
in a specific implementation.

## Motivation (what we want to enable)

Users should be able to flash GRiSP2 eMMC in two situations:

1) **Recovery**
- The board does not boot (bootloader damaged, bad system partition, etc.).
- The flashing entry point must not depend on the currently installed software.

2) **Provisioning / automation**
- Repeatable “factory reset / provision” flows in a lab or manufacturing setup.
- Scriptable and deterministic, suitable for CI runners or operator checklists.

Common requirement: start from **i.MX ROM Serial Downloader mode** (BOOT_MODE
pins/jumpers + power-cycle), because it is the lowest-level, most reliable entry
point.

## Desired UX (CLI-level)

A good UX likely looks like one primary command:

- `rebar3 grisp flash`

…with a small set of modes:

- default: least destructive flash that yields a bootable board
- `--bootloader`: full eMMC re-provisioning (more destructive)
- `--probe`: connectivity/info only (no writes)
- `--dry-run`: prepare/validate locally (no hardware)

The exact backend can vary, but the UX should remain stable.

## Technical pathways (how flashing could work)

Think of this as two stages:

1) **How do we gain control?** (ROM mode, bootloader shell, etc.)
2) **How do we actually write eMMC?** (fastboot/DFU/ums/TFTP/SD/serial)

The CLI can stay stable while we switch the backend.

### Pathway A: USB SDP (`uuu`) – *not supported on GRiSP2*

In theory, NXP `uuu` can flash i.MX devices by talking to the ROM over **USB SDP**
(typically the ROM enumerates as an NXP/Freescale USB device, often VID `15a2`).
A `uuu` bundle then boots a temporary loader and uses `FB:` fastboot commands.

On GRiSP2, the ROM does **not** appear to enumerate as an NXP USB SDP device on
Linux (no VID `15a2`). The board exposes an FT2232 USB–UART instead.

Therefore the USB SDP / `uuu` pathway should be treated as **not supported on
GRiSP2** unless proven otherwise.

### Pathway B (baseline): UART ROM downloader (`imx_uart`) → barebox → flash

This is the **documented upstream recovery approach**:
- Use Serial Downloader mode + `imx_uart` to upload a barebox image.
- Flash an eMMC image from the barebox shell (SD card or TFTP).

Source: https://github.com/grisp/grisp2-rtems-toolchain#recovery

Notes:
- This is the best-known supported path.
- The goal is automation; the serial console can still be driven programmatically.

### Pathway C: UART ROM downloader (`imx_uart`) → *fastboot-capable loader*

Even if USB SDP/`uuu` is not available, **fastboot can still be attractive** as
an automation-friendly flashing protocol if we can boot a loader that exposes
fastboot over USB *gadget*.

Sketch:
- Enter Serial Downloader mode.
- Use `imx_uart` to upload/boot a U-Boot (or other) image that auto-enters
  fastboot.
- Use `fastboot` tooling (or a small wrapper) to write/query eMMC.

This keeps the clean fastboot UX, but swaps the ROM transport to UART.

### Pathway D: barebox native “update modes” (when bootloader runs)

If the production bootloader (barebox) is intact, we can expose more convenient
update mechanisms that do not require toggling BOOT_MODE pins:
- USB gadget **fastboot** (if supported/enableable)
- USB gadget **DFU**
- USB gadget **mass storage** (UMS): export eMMC as a block device to the host
- Ethernet + TFTP/HTTP + `cp`/`uncompress`

These are not guaranteed to exist today, but they’re worth investigating.

## Documentation pointers

- Upstream GRiSP2 recovery (imx_uart): https://github.com/grisp/grisp2-rtems-toolchain#recovery
- Flash loader notes (historical/experimental uuu work): `docs/flash_loader.md` (in this repo)

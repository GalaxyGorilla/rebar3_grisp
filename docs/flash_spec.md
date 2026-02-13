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
2) **How do we actually write eMMC?** (fastboot/DFU/UMS/network)

The CLI can stay stable while we switch the backend.

### Pathway A (baseline): UART ROM downloader (`imx_uart`) → barebox → flash

This is the **documented upstream recovery approach**:
- Use Serial Downloader mode + `imx_uart` to upload a barebox image.
- From barebox, write an eMMC image (and/or partitions).

Source: https://github.com/grisp/grisp2-rtems-toolchain#recovery

Automation note:
- barebox may offer USB gadget modes (DFU/fastboot/UMS) that are more
  automation-friendly than interacting via serial terminal.

### Pathway B: UART ROM downloader (`imx_uart`) → fastboot endpoint

Even if USB SDP is not available, **fastboot can still be attractive** as an
automation-friendly flashing protocol if we can boot a loader that exposes
fastboot over USB *gadget*.

Two plausible variants:
- **B1 (preferred): `imx_uart` → barebox → `usbgadget -A ...`**
- **B2: `imx_uart` → U-Boot → fastboot**

Docs:
- `usbgadget` options include `-A` (fastboot), `-D` (DFU), `-S` (mass storage):
  https://www.barebox.org/doc/latest/commands/hwmanip/usbgadget.html
- barebox USB overview + fastboot support:
  https://www.barebox.org/doc/latest/user/usb.html

### Pathway C: barebox native “update modes” (when bootloader runs)

If barebox is intact, it may expose automation-friendly update mechanisms
without toggling BOOT_MODE pins.

Barebox supports USB gadget functions via `usbgadget`:
- `-A` Android **fastboot**
- `-D` **DFU**
- `-S` **USB mass storage** (UMS)

This suggests automated pathways:
- **fastboot gadget** (host uses `fastboot flash ...` / `getvar`)
- **DFU gadget** (host uses `dfu-util`)
- **UMS gadget** (host writes to exported block devices)
- Ethernet-based update flows

GRiSP2-specific validation needed:
- which USB controller/port can be used in device mode
- correct partition/export description for eMMC

## Documentation pointers

- Upstream GRiSP2 recovery (imx_uart): https://github.com/grisp/grisp2-rtems-toolchain#recovery

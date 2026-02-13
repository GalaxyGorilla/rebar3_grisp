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

### Pathway A: ROM → temporary loader → fastboot ("uuu style")

Idea:
- Use ROM Serial Downloader to upload and boot a temporary loader (often U-Boot).
- That loader exposes **USB fastboot**.
- Host flashes via fastboot commands.

Host tooling often used:
- NXP `uuu` (mfgtools) bundles: `SDP/SDPS/...` to boot loader, then `FB:` to
  flash/query.

Pros:
- Potentially very fast and automatable.
- Same host script can work whether you start in ROM mode or already in fastboot
  (when the script contains both stages).

Cons / risks:
- Must verify GRiSP2 support in practice.
- Requires a suitable temporary loader and correct storage layout assumptions.

Status note:
- Treat `uuu` on GRiSP2 as **experimental until validated on real hardware**.

### Pathway B: ROM → barebox via `imx_uart` → write eMMC from barebox

This is the **documented upstream recovery approach**:
- Build `imx_uart`.
- Use Serial Downloader mode to upload a barebox image.
- Flash an eMMC image from the barebox shell (SD card or TFTP).

Source:
- https://github.com/grisp/grisp2-rtems-toolchain#recovery

Pros:
- Known-supported for GRiSP2.
- Does not rely on fastboot.

Cons:
- More manual steps by default.
- Automation is possible but requires careful scripting around serial console.

### Pathway C: Booted bootloader update paths (non-ROM)

If the board boots into its production bootloader (barebox), there are classic
update routes:
- TFTP/HTTP fetch + `cp`/`uncompress` to `/dev/mmc...`
- SD-card based update

Pros:
- No need to toggle BOOT_MODE pins.

Cons:
- Not a recovery path if the bootloader is damaged.

## Documentation pointers

- Upstream GRiSP2 recovery: https://github.com/grisp/grisp2-rtems-toolchain#recovery
- Flash loader notes (if using Pathway A): `docs/flash_loader.md` (in this repo)

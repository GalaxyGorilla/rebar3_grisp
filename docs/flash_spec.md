# GRiSP2 flashing spec (rebar3_grisp + uuu)

This document specifies the intended user experience and CLI behavior for the
GRiSP2 eMMC flashing workflow implemented in this fork of `rebar3_grisp`.

## Motivation

Enable **recovery** and **provisioning automation** by flashing GRiSP2 eMMC from
an attached host using the NXP i.MX ROM **Serial Downloader** mode (BOOT_MODE
pins/jumpers).

Key properties:
- Works even if the installed bootloader/application is broken (ROM entry point).
- Scriptable for lab/manufacturing flows.
- Includes a no-write verification mode.

## Concepts

- **Serial Downloader (ROM)**: i.MX ROM USB download mode (`SDP/SDPS/...` stages).
- **Fastboot (bootloader gadget)**: protocol exposed by a temporary flash loader
  (U-Boot) to write/query storage (`FB:` stages).
- **uuu bundle**: a zip containing `uuu.auto` and payloads; `uuu` executes the
  appropriate stages depending on what it finds on USB.

## Command surface

### `rebar3 grisp flash`

Primary entry point for GRiSP2 flashing via `uuu`.

Modes:
- Default: flash system partition A (safer)
- `--bootloader`: flash full eMMC image (destructive)
- `--probe`: boot loader + print debug info (no eMMC writes)
- `--dry-run`: do everything except calling `uuu`

Common opts:
- `--relname`, `--relvsn`
- `--yes` (skip interactive confirmation)
- `--flash_loader <path>` (override bundled loader)

## Preconditions

Host:
- `uuu` in PATH
- `zip` in PATH
- USB permissions configured (Linux: run `uuu -udev` once if needed)

Board:
- Put GRiSP2 into Serial Downloader mode (BOOT_MODE pins/jumpers) + power cycle.

Flash loader:
- Default bundled loader: `priv/flash/flash_loader.bin`
- Must boot via ROM downloader and expose USB fastboot gadget.

Build docs: `docs/flash_loader.md` + `tools/build_flash_loader.sh`.

## Behavior by mode

### Default (system)

Command:

```sh
rebar3 grisp flash
```

Behavior:
1. Validate `uuu` + flash loader path.
2. Generate system firmware artifact via `rebar3 grisp firmware` (system only,
   uncompressed).
3. Create a `uuu.auto` that boots loader via SDP/SDPS then writes `sys.img` to
   eMMC system partition A.
4. Zip bundle + run `uuu <bundle.zip>`.

Safety:
- Prompts unless `--yes`.

### Full image (`--bootloader`)

Command:

```sh
rebar3 grisp flash --bootloader
```

Behavior:
- Generate full eMMC image artifact via `rebar3 grisp firmware` (image,
  `--truncate false`, uncompressed) and write from sector 0.

Safety:
- Prompts unless `--yes`.

### Probe (`--probe`)

Command:

```sh
rebar3 grisp flash --probe
```

Behavior:
- Boot loader via SDP/SDPS.
- Run only read-only fastboot `ucmd` commands to verify loader/USB/storage and
  print debug info:
  - marker echo
  - `version`, `bdinfo`
  - DT/env vars: `fdtfile`, `fdtcontroladdr`, `fdt_addr_r`, `fdtdir`, `bootcmd`
  - storage: `mmc list`, `mmc dev 1`, `mmc info`
- No eMMC writes.

### Dry-run (`--dry-run`)

Command:

```sh
rebar3 grisp flash --dry-run
```

Intended behavior:
- Validate inputs.
- Generate artifacts as needed (system/image) and generate `uuu.auto`.
- Create a zip bundle under `_grisp/flash/`.
- Do **not** invoke `uuu`.

## Notes and UX expectations

- The task never calls `sudo` automatically.
- On USB permission errors, it should recommend `uuu -udev`.
- Output should be explicit about what will be flashed (system vs full image).

## Tarball-only deploy coupling

Firmware generation uses `rebar3 grisp deploy --tar` internally to create a
release bundle. For `flash` to be usable in environments where deploy destinations
are OS-specific (e.g. `/Volumes/GRISP`), the deploy task should support
**tarball-only** mode that does not require a copy destination and does not run
copy scripts.

(Implemented in this fork.)

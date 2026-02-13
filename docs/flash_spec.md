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

## Recommendation (preferred backend + rationale)

**Preferred implementation target:**

- **`imx_uart` (UART ROM bootstrap) → barebox → USB gadget fastboot/DFU/UMS**

Rationale:
- **Matches GRiSP2 reality:** the board reliably exposes UART in ROM Serial
  Downloader mode (FT2232), while USB SDP is not available.
- **Barebox-first:** GRiSP2 already prioritizes barebox; using its update
  frameworks reduces divergence from upstream and avoids introducing an extra
  bootloader layer unnecessarily.
- **Automation-friendly endpoint:** once barebox is running, exposing a USB
  gadget function (preferably **fastboot**) yields a clean host-side protocol
  for scripted flashing.
- **Stable CLI, swappable internals:** the CLI can stay `rebar3 grisp flash ...`
  while the backend evolves (fastboot vs DFU vs UMS, different partition maps,
  etc.).

Fallbacks if barebox gadget fastboot is not viable on GRiSP2:
- **`imx_uart` → barebox → DFU** (still host-driven, widely available tooling)
- **`imx_uart` → barebox → UMS** (simple but riskier; host writes raw blocks)
- **`imx_uart` → U-Boot → fastboot** (extra moving parts, but a practical plan B)

## Implementation plan (phased)

### Phase 0: Define what “flash” means (artifacts + partitions)
- Pick the minimal “bootable” set for default mode (e.g. write system partition
  only), and define `--bootloader` as “full eMMC reprovisioning”.
- Decide artifact format(s): raw `.img` vs partition images; keep it aligned
  with existing `rebar3 grisp firmware` outputs.

### Phase 1: Make ROM bootstrap reliable (`imx_uart` integration)
- Add a backend module that:
  - locates `imx_uart` on PATH (or supports an explicit config key)
  - selects the correct UART device (allow `--port /dev/ttyUSB…`)
  - uploads/boots a known-good barebox image
- `--probe` at this stage can verify: UART connectivity, boot banner
  synchronization, and that barebox reached a prompt.

### Phase 2: Prefer fastboot gadget via barebox `usbgadget -A`
- We will need an **appropriate barebox image** for this workflow:
  - boots on GRiSP2 when loaded via `imx_uart`
  - enables the required USB device controller in *peripheral* mode
  - either **auto-starts `usbgadget -A ...`** (ideal: “boot straight into fastboot”)
    or runs an init script that starts it deterministically.
- In barebox, start the gadget with a partition description exporting the eMMC
  target(s), e.g. `usbgadget -A <desc>` (optionally add `-a` for USB ACM console).
- On the host, use `fastboot getvar` to confirm connectivity, then `fastboot flash`
  to write partitions.
- Map CLI modes to fastboot operations:
  - default: flash system/rootfs partition(s)
  - `--bootloader`: include barebox/env/boot partitions as needed
  - `--probe`: `fastboot getvar all` (plus any non-destructive queries)

### Phase 3: Add DFU / UMS fallbacks (still via barebox)
- DFU: start `usbgadget -D <desc>` and flash with `dfu-util`.
- UMS: start `usbgadget -S <desc>` and write using safe host tooling.
- Backend selection can be automatic (prefer fastboot; fall back if tools/USB
  enumeration fail) or explicit (`--backend fastboot|dfu|ums`).

### Phase 4: Hardening + UX
- Ensure `--dry-run` goes as far as possible: validate artifacts, generate the
  partition export description, check host tooling availability, but do not
  touch hardware.
- Add “operator checklist” output for the only required manual step:
  “Set BOOT_MODE pins to Serial Downloader and power-cycle.”
- Capture logs (UART transcript + host fastboot/dfu logs) for reproducibility.

## Documentation pointers

- Upstream GRiSP2 recovery (imx_uart): https://github.com/grisp/grisp2-rtems-toolchain#recovery
- barebox USB gadget docs (`usbgadget`, fastboot/DFU/UMS):
  https://www.barebox.org/doc/latest/user/usb.html
  https://www.barebox.org/doc/latest/commands/hwmanip/usbgadget.html

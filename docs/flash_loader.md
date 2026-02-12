# GRiSP2 flash_loader.bin (i.MX6ULL / phyCORE PCL-063)

This document explains how to **build the `flash_loader.bin`** used by
`rebar3 grisp flash`.

The `flash_loader.bin` is a special bootloader image that is **booted via the
ROM Serial Downloader (SDP)** (using NXP `uuu`). It must:

- boot on the GRiSP2 i.MX6ULL SOM (Phytec phyCORE / PCL-063)
- bring up USB gadget fastboot
- **auto-enter fastboot** (no interactive prompt)

## Upstream used

We use NXP's U-Boot fork:

- Repo: https://github.com/nxp-imx/uboot-imx
- Commit tested: `4ddbad60eff308a5b356fb9ab8734ac382ddd692`
- Base defconfig: `phycore_pcl063_ull_defconfig`

The build output we use as flash loader is:

- `u-boot-with-spl.imx`  → rename/copy to `flash_loader.bin`

## Host requirements

You need a Linux host.

Tools:

- `git`, `make`
- ARM32 cross compiler: `arm-linux-gnueabihf-gcc` (Debian/Ubuntu package: `gcc-arm-linux-gnueabihf`)
- U-Boot build deps: `bc`, `bison`, `flex`, `libssl-dev`
- Host deps pulled in by U-Boot tools: `libgnutls28-dev`

Ubuntu/Debian example:

```bash
sudo apt-get update
sudo apt-get install -y \
  gcc-arm-linux-gnueabihf bc bison flex libssl-dev make git \
  libgnutls28-dev
```

## Build

A reference script exists at:

- `tools/build_flash_loader.sh`

Manual steps (for transparency):

```bash
git clone https://github.com/nxp-imx/uboot-imx.git
cd uboot-imx

git checkout 4ddbad60eff308a5b356fb9ab8734ac382ddd692

make distclean
make phycore_pcl063_ull_defconfig

# Enable fastboot + uuu support and force auto-fastboot
scripts/config --file .config \
  -e CMD_FASTBOOT \
  -e USB_FUNCTION_FASTBOOT \
  -e FASTBOOT \
  -e FASTBOOT_FLASH \
  -e FASTBOOT_UUU_SUPPORT

# Provide mandatory buffer settings (example addresses; adjust if needed)
scripts/config --file .config --set-val FASTBOOT_BUF_ADDR 0x82000000
scripts/config --file .config --set-val FASTBOOT_BUF_SIZE 0x10000000

# Auto-enter fastboot
scripts/config --file .config --set-val BOOTDELAY 0
scripts/config --file .config --set-str BOOTCOMMAND 'fastboot 0'

# Avoid SPL USB host codepaths we don't need for gadget fastboot
scripts/config --file .config -d SPL_USB_HOST -d USB_HOST -d USB_EHCI_HCD -d USB_EHCI_MX6

# Avoid board-specific LDO hook (not implemented on this board)
scripts/config --file .config -d LDO_BYPASS_CHECK

make olddefconfig
make -j"$(nproc)" CROSS_COMPILE=arm-linux-gnueabihf-

cp -v u-boot-with-spl.imx flash_loader.bin
```

## Notes

- The exact `FASTBOOT_BUF_ADDR` / `FASTBOOT_BUF_SIZE` values are platform-specific.
  The above values worked for building; runtime validation on GRiSP2 hardware is still required.
- This flash loader is intended for the **recovery + flashing** flow only.
  It should not be used as the production bootloader image.

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="${ROOT}/_grisp/flash"
UBOOT_DIR="${ROOT}/_grisp/tmp/uboot-imx"

UBOOT_REPO="https://github.com/nxp-imx/uboot-imx.git"
UBOOT_COMMIT="4ddbad60eff308a5b356fb9ab8734ac382ddd692"
DEFCONFIG="phycore_pcl063_ull_defconfig"

CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnueabihf-}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

need git
need make
need "${CROSS_COMPILE}gcc"
need bc
need bison
need flex

mkdir -p "${OUTDIR}" "${ROOT}/_grisp/tmp"

if [[ ! -d "${UBOOT_DIR}/.git" ]]; then
  rm -rf "${UBOOT_DIR}"
  git clone "${UBOOT_REPO}" "${UBOOT_DIR}"
fi

cd "${UBOOT_DIR}"
git fetch --all --tags -q

git checkout -q "${UBOOT_COMMIT}"

echo "==> Configuring U-Boot (${DEFCONFIG})"
make distclean >/dev/null
make "${DEFCONFIG}" >/dev/null

# Enable fastboot + uuu support and force auto-fastboot
scripts/config --file .config \
  -e CMD_FASTBOOT \
  -e USB_FUNCTION_FASTBOOT \
  -e FASTBOOT \
  -e FASTBOOT_FLASH \
  -e FASTBOOT_UUU_SUPPORT

# Mandatory fastboot buffer settings
scripts/config --file .config --set-val FASTBOOT_BUF_ADDR 0x82000000
scripts/config --file .config --set-val FASTBOOT_BUF_SIZE 0x10000000

# Auto-enter fastboot
scripts/config --file .config --set-val BOOTDELAY 0
scripts/config --file .config --set-str BOOTCOMMAND 'fastboot 0'

# Disable SPL USB host codepaths (we only need gadget)
scripts/config --file .config -d SPL_USB_HOST -d USB_HOST -d USB_EHCI_HCD -d USB_EHCI_MX6

# Avoid LDO bypass hook (not implemented on all boards)
scripts/config --file .config -d LDO_BYPASS_CHECK

make olddefconfig >/dev/null

echo "==> Building"
make -j"$(nproc)" CROSS_COMPILE="${CROSS_COMPILE}"

if [[ ! -f u-boot-with-spl.imx ]]; then
  echo "Build did not produce u-boot-with-spl.imx" >&2
  exit 1
fi

cp -v u-boot-with-spl.imx "${OUTDIR}/flash_loader.bin"

echo "==> Wrote: ${OUTDIR}/flash_loader.bin"

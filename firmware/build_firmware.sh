#!/usr/bin/env bash
# Builds EDK2 ArmVirtQemu (AARCH64, RELEASE) with the "host picks the resolution" ramfb
# patch (firmware/patch_ramfb.py). Linux host with: gcc-aarch64-linux-gnu acpica-tools
# nasm uuid-dev python3 git. Output: $1 (default firmware/out/edk2-aarch64-code.fd).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${EDK2_TAG:-edk2-stable202608}"
OUT="${1:-$ROOT/firmware/out/edk2-aarch64-code.fd}"
WORK="${EDK2_WORK:-$ROOT/firmware/work}"

mkdir -p "$WORK" "$(dirname "$OUT")"
if [ ! -d "$WORK/edk2" ]; then
  git clone -q --depth 1 -b "$TAG" https://github.com/tianocore/edk2 "$WORK/edk2"
  git -C "$WORK/edk2" submodule update --init --depth 1 --jobs 8
fi
cd "$WORK/edk2"
git checkout -q -- OvmfPkg/QemuRamfbDxe/QemuRamfb.c
python3 "$ROOT/firmware/patch_ramfb.py" OvmfPkg/QemuRamfbDxe/QemuRamfb.c
make -C BaseTools -j"$(nproc)" >/dev/null
export GCC_AARCH64_PREFIX=aarch64-linux-gnu-
set +u; . ./edksetup.sh >/dev/null; set -u
build -a AARCH64 -t GCC -p ArmVirtPkg/ArmVirtQemu.dsc -b RELEASE -n "$(nproc)" -q
cp Build/ArmVirtQemu-AArch64/RELEASE_GCC/FV/QEMU_EFI.fd "$OUT"
ls -l "$OUT"

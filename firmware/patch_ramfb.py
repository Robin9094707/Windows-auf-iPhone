#!/usr/bin/env python3
"""Patch EDK2's QemuRamfbDxe so the host (Windows auf iPhone) can pick the screen resolution.

The app passes fw_cfg file "opt/org.winiphone/resolution" = two little-endian UINT32
(width, height). The driver then offers exactly that one GOP mode, so the UEFI console,
the Windows boot loader and Windows' Basic Display driver all use it – e.g. the
iPhone 17 Pro Max's 19.5:9 panel instead of 800x600/1024x768.
"""
import sys

path = sys.argv[1]
raw = open(path, "rb").read().decode("utf-8")
crlf = "\r\n" in raw
src = raw.replace("\r\n", "\n")

def replace_once(old, new):
    global src
    if src.count(old) != 1:
        sys.exit(f"patch_ramfb: anchor not found exactly once: {old[:60]!r}")
    src = src.replace(old, new)

replace_once(
    "STATIC FIRMWARE_CONFIG_ITEM    mRamfbFwCfgItem;",
    "STATIC FIRMWARE_CONFIG_ITEM    mRamfbFwCfgItem;\nSTATIC BOOLEAN                 mCustomResolution;",
)

replace_once(
    "  MaxFbSize = 0;\n  for (Index = 0; Index < ARRAY_SIZE (mQemuRamfbModeInfo); Index++) {",
    """  //
  // Windows auf iPhone: host-selected resolution (see firmware/patch_ramfb.py).
  //
  {
    FIRMWARE_CONFIG_ITEM  ResItem;
    UINTN                 ResSize;
    UINT32                Res[2];

    if (!EFI_ERROR (QemuFwCfgFindFile ("opt/org.winiphone/resolution", &ResItem, &ResSize)) &&
        (ResSize == sizeof (Res)))
    {
      QemuFwCfgSelectItem (ResItem);
      QemuFwCfgReadBytes (sizeof (Res), Res);
      if ((Res[0] >= 640) && (Res[0] <= 7680) && (Res[1] >= 480) && (Res[1] <= 4320)) {
        mQemuRamfbModeInfo[0].HorizontalResolution = Res[0] & ~7U;
        mQemuRamfbModeInfo[0].VerticalResolution   = Res[1] & ~1U;
        mQemuRamfbMode.MaxMode                     = 1;
        mCustomResolution                          = TRUE;
        DEBUG ((DEBUG_INFO, "Ramfb: host resolution %ux%u\\n", Res[0], Res[1]));
      }
    }
  }

  MaxFbSize = 0;
  for (Index = 0; Index < mQemuRamfbMode.MaxMode; Index++) {""",
)

replace_once(
    "  QemuRamfbGraphicsOutputSetMode (&mQemuRamfbGraphicsOutput, 1);",
    "  QemuRamfbGraphicsOutputSetMode (&mQemuRamfbGraphicsOutput, mCustomResolution ? 0 : 1);",
)

if "mCustomResolution" in raw:
    sys.exit("patch_ramfb: already patched")
open(path, "wb").write((src.replace("\n", "\r\n") if crlf else src).encode("utf-8"))
print("patch_ramfb: QemuRamfb.c patched")

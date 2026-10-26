#!/usr/bin/env python3
"""Extracts the kernel and initrd from an Ubuntu live-server ISO (arm64), for booting the
installer directly with Virtualization.framework (which needs an uncompressed arm64 Image).

The ISO's casper/vmlinuz is an EFI application wrapping a zboot image whose zstd payload is the
Image. macOS can't mount these ISOs, so bsdtar reads them. Decompression uses Python 3.14's
compression.zstd, or Homebrew's zstd when that isn't there.

Usage: extract-iso-kernel.py <iso> <output dir>   -> <output dir>/Image, <output dir>/initrd
"""
import os
import shutil
import struct
import subprocess
import sys


def decompress(data: bytes) -> bytes:
    try:
        from compression import zstd  # Python 3.14+
        return zstd.decompress(data)
    except ImportError:
        zstd_bin = shutil.which("zstd") or "/opt/homebrew/bin/zstd"
        return subprocess.run([zstd_bin, "-d", "-c"], input=data, capture_output=True, check=True).stdout


def main() -> None:
    iso, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    subprocess.run(["bsdtar", "-xf", iso, "-C", out, "casper/vmlinuz", "casper/initrd"], check=True)
    vmlinuz = open(os.path.join(out, "casper/vmlinuz"), "rb").read()
    zb = vmlinuz.find(b"zimg") - 4  # the zboot header: "MZ", "zimg", payload offset, payload size
    if zb < 0:
        sys.exit("no zboot image in casper/vmlinuz")
    off, size = struct.unpack("<II", vmlinuz[zb + 8:zb + 16])
    image = decompress(vmlinuz[zb + off:zb + off + size])
    if image[0x38:0x3C] != b"ARM\x64":
        sys.exit("decompressed payload is not an arm64 Image")
    open(os.path.join(out, "Image"), "wb").write(image)
    os.replace(os.path.join(out, "casper/initrd"), os.path.join(out, "initrd"))
    shutil.rmtree(os.path.join(out, "casper"))
    print(f"Image {len(image)} bytes, initrd {os.path.getsize(os.path.join(out, 'initrd'))} bytes")


if __name__ == "__main__":
    main()

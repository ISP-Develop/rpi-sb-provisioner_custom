#!/usr/bin/env python3
# P4-5c (rpi-sb-provisioner 2.3.5 initramfs): `cryptsetup resize cryptroot` with the firmware-HMAC passphrase.
#
# The first-boot carving of p2 (6GiB wall, then p3) resizes the opened cryptroot. It fed the raw OTP key
# (cryptkey-fetch) as the passphrase, which is locked under lock_device_private_key=1 and is not the p2
# passphrase any more (2.3.5 `oem cryptinit` sets hex(HMAC(key-id 1, block-device-id))).
# Uses dtebx_p2_pass() defined by P4-4, so this must be applied after p4-4_initramfs_hmac.py
# (build-initramfs-2.3.5.sh applies patches in name order).
#
# Usage: python3 p4-5c_initramfs_resize.py <path/to/init_cryptroot.sh>
# Idempotent (marker DTEBX_P45C_RESIZE_V235).
import sys
from pathlib import Path

MARK = "DTEBX_P45C_RESIZE_V235"
path = Path(sys.argv[1])
s = path.read_text()
if MARK in s:
    print(f"already patched: {path}")
    raise SystemExit(0)
if "dtebx_p2_pass_check() {" not in s:
    raise SystemExit(f"{path}: dtebx_p2_pass_check() not found (apply p4-4 first); not modified")

A = "  /usr/bin/cryptkey-fetch | /sbin/cryptsetup resize cryptroot\n"
B = (f"  # {MARK}: check the passphrase source (dtebx_p2_pass_check, P4-4) and the resize result; on failure reboot.\n"
     "  #   After a reboot the partition table is already reshaped (parted ran before this), so the next boot takes\n"
     "  #   'Partition already shaped' and luksOpen maps the shrunk p2: it does not come back here (no loop).\n"
     "  if ! { dtebx_p2_pass_check && dtebx_p2_pass | /sbin/cryptsetup resize cryptroot; }; then\n"
     "    echo \"FATAL(resize): cryptsetup resize cryptroot failed (passphrase check or resize, see above); rebooting in 30 s.\"\n"
     "    sleep 30 && reboot -f\n"
     "  fi\n")
n = s.count(A)
if n != 2:
    raise SystemExit(f"{path}: resize anchor found {n} times (expected 2: mainline and r2 first boot); not modified")
s = s.replace(A, B)
path.write_text(s)
print(f"patched: {path}")

#!/usr/bin/env python3
# P4-5a (rpi-sb-provisioner 2.3.5 initramfs): create p3's LUKS in the initramfs, keyed by the firmware HMAC.
#
# Before: the initramfs only carved an empty p3; firstboot-partition-setup.sh (rootfs) then re-created p3 on a
# 1MiB boundary, derived the p3 key from the raw OTP key and ran luksFormat/open. Under
# lock_device_private_key=1 the raw key is unreadable everywhere, and after P4-7 closes HMAC nothing after
# switch_root can derive the key. So the key-dependent part (luksFormat + open) moves here.
# See ~/deforion/docs/assets/20260929_firstboot_p3_scope.md §5-1.
#
#   1. p3 is created on a 1MiB boundary here (TARGET_P2_SIZE + 2048; TARGET_P2_SIZE = 6GiB is a multiple of
#      2048), i.e. the same start firstboot's align_up() produced, so firstboot no longer re-creates it.
#   2. First boot only (no /mnt/etc/cryptsetup-keys/.p3_initialized and p3 present): luksFormat p3 with
#      derive_p3_key (P4-4: firmware HMAC) UNCONDITIONALLY and open it as cryptlvm - exactly like the 2.0.4
#      firstboot, which always re-created p3 when the marker was absent.
#      ★2026-09-29 fix: the first version also required "p3 is not LUKS yet". On 1 号機 the provisioner's
#      `fastboot erase` (BLKSECDISCARD/BLKDISCARD) did not clear the old p3, whose LUKS header sits exactly at the
#      new p3 start (same 1MiB-aligned position), so the format was skipped and the OLD p3 (2026-09-20 LVs) was
#      opened; firstboot's pvcreate then refused the existing vg_data PV. The marker alone decides "first boot". cryptlvm stays open
#      across switch_root; firstboot-partition-setup.sh (pi-gen, P4-5a) sees it and builds LVM on it.
#   3. The regular p3 open is skipped when cryptlvm is already open.
#
# Requires p4-4_initramfs_hmac.py (derive_p3_key via firmware HMAC). Applied in name order by
# build-initramfs-2.3.5.sh. Usage: python3 p4-5a_initramfs_p3.py <path/to/init_cryptroot.sh>
# Idempotent (marker DTEBX_P45A_P3_V235).
import sys
from pathlib import Path

MARK = "DTEBX_P45A_P3_V235"
path = Path(sys.argv[1])
s = path.read_text()
if MARK in s:
    print(f"already patched: {path}")
    raise SystemExit(0)
if "DTEBX_P44_HMAC_V235" not in s:
    raise SystemExit(f"{path}: P4-4 not applied (derive_p3_key must use the firmware HMAC); not modified")

A1 = 'TARGET_P3_START="$((TARGET_P2_SIZE + 1))s"\n'
B1 = (f'# {MARK}: p3 starts on a 1MiB boundary (TARGET_P2_SIZE is a multiple of 2048) = the start that\n'
      '#   firstboot-partition-setup.sh align_up() used to re-create; p3 is final here because its LUKS is made below.\n'
      'TARGET_P3_START="$((TARGET_P2_SIZE + 2048))s"\n')

A2 = 'if dtebx_p3_key_ok; then\n  echo "Opening cryptlvm..."\n'
B2 = (f'# {MARK}: first boot only - make p3\'s LUKS here (the key cannot be derived after switch_root).\n'
      '#   cryptlvm stays open across switch_root; firstboot-partition-setup.sh builds LVM on it.\n'
      '#   The marker alone decides "first boot": an old LUKS header left on the eMMC (discard does not zero it) is\n'
      '#   overwritten (--batch-mode), like the 2.0.4 firstboot did.\n'
      'if [ ! -e /mnt/etc/cryptsetup-keys/.p3_initialized ] && [ -b /dev/mmcblk0p3 ]; then\n'
      '  echo "p3: first boot -> luksFormat with the firmware-HMAC key (P4-5a)"\n'
      '  if dtebx_p3_key_ok; then\n'
      '    if derive_p3_key | /sbin/cryptsetup luksFormat /dev/mmcblk0p3 --key-file - --batch-mode \\\n'
      '       && derive_p3_key | /sbin/cryptsetup open /dev/mmcblk0p3 cryptlvm --key-file -; then\n'
      '      echo "p3: LUKS created and opened as cryptlvm; firstboot-partition-setup.sh builds LVM on it"\n'
      '    else\n'
      '      echo "FATAL(p3): luksFormat/open of p3 failed; the data partition will NOT be set up." >&2\n'
      '    fi\n'
      '  else\n'
      '    echo "FATAL(p3): cannot derive the p3 key (firmware HMAC); the data partition will NOT be set up." >&2\n'
      '  fi\n'
      'fi\n'
      + A2)

A3 = '  derive_p3_key | /sbin/cryptsetup luksOpen /dev/mmcblk0p3 "cryptlvm" --key-file -\n'
B3 = (f'  # {MARK}: already open when p3 was just created above (first boot)\n'
      '  [ -e /dev/mapper/cryptlvm ] || derive_p3_key | /sbin/cryptsetup luksOpen /dev/mmcblk0p3 "cryptlvm" --key-file -\n')

problems = [f"{n} found {s.count(a)} times" for n, a in (("TARGET_P3_START", A1), ("p3 open block", A2), ("p3 luksOpen", A3)) if s.count(a) != 1]
if problems:
    raise SystemExit(f"{path}: " + "; ".join(problems) + "; not modified")
s = s.replace(A1, B1, 1).replace(A2, B2, 1).replace(A3, B3, 1)
path.write_text(s)
print(f"patched: {path}")

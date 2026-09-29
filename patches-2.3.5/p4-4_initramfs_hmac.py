#!/usr/bin/env python3
# P4-4 (rpi-sb-provisioner 2.3.5 initramfs): unlock with the firmware HMAC instead of the raw OTP key.
#
# Applied to a COPY of work/extract_initramfs/usr/bin/init_cryptroot.sh by build-initramfs-2.3.5.sh.
# The 2.0.4 tree (work/extract_initramfs, used by prov for the second testbed) is never modified.
#
# Why: rpi-sb-provisioner 2.3.5 always puts lock_device_private_key=1 into the signed config.txt. The
# firmware applies it before the initramfs runs, so the raw OTP key (mailbox 0x00030081, cryptkey-fetch)
# cannot be read here either. Only the firmware HMAC (key-id 1) is available.
#
#   p2: passphrase = hex(HMAC(key-id 1, block-device-id /dev/mmcblk0)), exactly what upstream 2.3.5 uses
#       (cryptkey-rpifwcrypto:32) and what the 2.3.5 gadget's `oem cryptinit` sets (rpi-fastbootd
#       commands.cpp:287-311). No fallback to the raw key: it is locked anyway, and the P4 completion
#       condition is that no raw-key keyslot exists.
#   p3: key = HMAC(key-id 1, "dtebx-p3-luks-v1") as 32 raw bytes (--key-file -). Same label as before.
#
# Secrets are only ever piped, never put in a shell variable: this script runs with `set -x` and its
# output goes to the serial console.
#
# Not in this patch: cryptsetup resize (:163, :184) = P4-5c; pcr_decoy_seed (:874-887) = P4-5b;
# closing HMAC after unlock = P4-7.
#
# Usage: python3 p4-4_initramfs_hmac.py <path/to/init_cryptroot.sh>
# Idempotent (marker DTEBX_P44_HMAC_V235). Writes nothing unless every anchor is found exactly once.
import sys
from pathlib import Path

MARK = "DTEBX_P44_HMAC_V235"
path = Path(sys.argv[1])
s = path.read_text()
if MARK in s:
    print(f"already patched: {path}")
    raise SystemExit(0)

A_P2 = ('/usr/bin/cryptkey-fetch | /sbin/cryptsetup luksOpen /dev/mmcblk0p2 cryptroot || {\n'
        '    echo "FATAL: LUKS open failed."\n')
B_P2 = (f'# {MARK}: p2 passphrase = hex(firmware HMAC(key-id 1, block-device-id)). Same as upstream 2.3.5 and\n'
        '#   the 2.3.5 gadget `oem cryptinit`. The raw OTP key is locked (lock_device_private_key=1), so no fallback.\n'
        '#   Piped only (set -x would print a variable to the serial console).\n'
        'dtebx_p2_pass() {\n'
        '  /usr/bin/block-device-id /dev/mmcblk0 | /usr/bin/rpi-fw-crypto hmac --in /dev/stdin --key-id 1 --outform hex\n'
        '}\n'
        '# Check the passphrase source before use, still piped (no secret in a variable). Two causes are told apart in\n'
        '#   the log because they point at different things in P6: the eMMC CID (block-device-id) or the firmware HMAC.\n'
        '#   rpi-fw-crypto hmac succeeds on an EMPTY input and sh pipelines only report the last exit code, so a failed\n'
        '#   block-device-id would otherwise yield a well-formed but wrong passphrase. The stderr reason shown drops set -x\n'
        '#   trace lines ("+ ..."), which the function call would otherwise capture instead of the tool message.\n'
        'dtebx_p2_pass_check() {\n'
        '  if ! /usr/bin/block-device-id /dev/mmcblk0 2>/dev/null | /usr/bin/busybox grep -qxE "[0-9a-f]{32}"; then\n'
        '    echo "FATAL(p2-pass): CID unavailable: block-device-id /dev/mmcblk0 did not return 32 hex digits ($(/usr/bin/block-device-id /dev/mmcblk0 2>&1 >/dev/null | /usr/bin/busybox grep -v "^+" | /usr/bin/busybox head -n 3 | /usr/bin/busybox tr "\\n" " "))"\n'
        '    return 1\n'
        '  fi\n'
        '  if ! dtebx_p2_pass 2>/dev/null | /usr/bin/busybox grep -qxE "[0-9a-f]{64}"; then\n'
        '    echo "FATAL(p2-pass): firmware HMAC unavailable: rpi-fw-crypto hmac (key-id 1) did not return 64 hex digits ($(dtebx_p2_pass 2>&1 >/dev/null | /usr/bin/busybox grep -v "^+" | /usr/bin/busybox head -n 3 | /usr/bin/busybox tr "\\n" " "))"\n'
        '    return 1\n'
        '  fi\n'
        '  return 0\n'
        '}\n'
        'dtebx_p2_pass_check || { echo "FATAL: p2 passphrase unavailable; rebooting in 30 s."; sleep 30 && reboot -f; }\n'
        'dtebx_p2_pass | /sbin/cryptsetup luksOpen /dev/mmcblk0p2 cryptroot || {\n'
        '    echo "FATAL: LUKS open failed (firmware HMAC passphrase)."\n')

p3_start = s.find("derive_p3_key() {\n")
p3_end = s.find("\n}\n", p3_start)
A_P3 = s[p3_start:p3_end + 3] if p3_start >= 0 and p3_end >= 0 else None
B_P3 = ('derive_p3_key() {\n'
        f'  # {MARK}: p3 key = firmware HMAC(key-id 1, label), 32 raw bytes. The raw OTP key is locked here\n'
        '  #   (lock_device_private_key=1), so the old cryptkey-fetch + openssl derivation cannot run.\n'
        '  #   rpifwcrypto README:169-172 states this equals openssl HMAC keyed with the raw OTP value.\n'
        '  printf %s "${P3_KEY_LABEL}" | /usr/bin/rpi-fw-crypto hmac --in /dev/stdin --key-id 1\n'
        '}\n'
        f'# {MARK}: the p3 key is usable only if derive_p3_key exits 0 AND yields exactly 32 bytes. Only the byte count\n'
        '#   reaches a variable (set -x), never the key.\n'
        'dtebx_p3_key_ok() {\n'
        '  derive_p3_key > /dev/null 2>&1 || return 1\n'
        '  [ "$(derive_p3_key 2>/dev/null | /usr/bin/busybox wc -c | /usr/bin/busybox tr -d \' \')" = 32 ]\n'
        '}\n')

problems = []
if s.count(A_P2) != 1:
    problems.append(f"p2 anchor found {s.count(A_P2)} times")
if A_P3 is None or s.count("derive_p3_key() {\n") != 1 or "cryptkey-fetch" not in A_P3:
    problems.append("derive_p3_key() not found once / not the cryptkey-fetch version")
if problems:
    raise SystemExit(f"{path}: " + "; ".join(problems) + "; not modified")

s = s.replace(A_P2, B_P2, 1)
s = s.replace(A_P3, B_P3, 1)
A_OPEN = 'if derive_p3_key > /dev/null 2>&1; then\n  echo "Opening cryptlvm..."\n'
if s.count(A_OPEN) != 1:
    raise SystemExit(f"{path}: p3 open check found {s.count(A_OPEN)} times; not modified")
s = s.replace(A_OPEN, 'if dtebx_p3_key_ok; then\n  echo "Opening cryptlvm..."\n', 1)
# The failure message of that block still named the raw-key path (2026-09-29): point it at the firmware HMAC.
A_MSG = ('  echo "FATAL: could not derive the p3 LUKS key from OTP; the data partition will NOT be mounted." >&2\n'
         '  echo "       check: cryptkey-fetch / base64 / od / openssl in this initramfs, and the OTP private-key rows." >&2\n')
B_MSG = ('  echo "FATAL: could not derive the p3 LUKS key (firmware HMAC, key-id 1); the data partition will NOT be mounted." >&2\n'
         '  echo "       check: rpi-fw-crypto in this initramfs, and key 1 status (HMAC must not be locked before this point)." >&2\n')
if s.count(A_MSG) != 1:
    raise SystemExit(f"{path}: p3 failure message found {s.count(A_MSG)} times; not modified")
s = s.replace(A_MSG, B_MSG, 1)
path.write_text(s)
print(f"patched: {path}")

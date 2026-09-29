#!/usr/bin/env python3
# P4-7 (rpi-sb-provisioner 2.3.5 initramfs): close the firmware HMAC (and raw read) of key 1 before switch_root.
#
# Decision (2026-09-29, 案 B): if the lock cannot be confirmed, do NOT switch_root; reboot (loop).
#
# Where: immediately before `systemctl switch-root`. Every HMAC user is earlier on every path:
#   first boot : p2 unlock -> cryptsetup resize (mainline or r2) -> p3 luksFormat/open (P4-5a) -> p3 open block
#   later boots: p2 unlock -> p3 open block
#   Everything after the p3 open block (LVM mounts, restore/erase, pcr_decoy_seed v2, pcr_diag) uses no HMAC,
#   and all paths (incl. the failure branches that do not reboot) converge on switch-root.
#   cryptroot.service runs once per boot (runs.log grows by one line per boot:
#   ~/deforion/docs/assets/20260917_stepF_ima_lockdown_verification_procedure.md:254), so no later run needs HMAC.
#
# How: rpi-fw-crypto (20260626, in the initramfs) `set-key-status 1 READ_LOCKED HMAC_LOCKED`. READ_LOCKED is passed
#   too because the written value may replace the status (rpi-fastbootd ORs the current status before writing).
#   The exit code is NOT trusted: rpi_fw_crypto_set_key_status() does not check the firmware's error bit
#   (utils rpifwcrypto.c:441-462). Success = get-key-status afterwards has both bit8 (READ_LOCKED) and bit11
#   (HMAC_LOCKED). Measured on prov2 (2026-09-29): status 0x901 after the call, HMAC then fails with
#   "4 (Key is locked)", and writing status 0 via SET_CRYPTO_KEY_STATUS is refused (stays locked until reboot).
#
# Retries: 5 attempts, 1 s apart. A mailbox call is a synchronous few-ms operation, so a transient failure is
#   expected to clear within a second; 5 x 1 s absorbs up to ~4 s. Cost: 0 s when the first attempt succeeds,
#   ~5 s worst case, far below the 5 min watchdog.
# On failure: message on the console, append to /mnt/var/log/dtebx-hmac-lock-failed.log (writable here: lv_log is
#   mounted at /mnt/var/log on later boots, the overlay upper on first boot and firstboot moves it into lv_log),
#   sync, then `sleep 30 && reboot -f` like the other FATAL paths of this script.
#
# Usage: python3 p4-7_initramfs_hmac_lock.py <path/to/init_cryptroot.sh>
# Idempotent (marker DTEBX_P47_HMAC_LOCK_V235). Requires P4-4 (rpi-fw-crypto in the initramfs).
import sys
from pathlib import Path

MARK = "DTEBX_P47_HMAC_LOCK_V235"
path = Path(sys.argv[1])
s = path.read_text()
if MARK in s:
    print(f"already patched: {path}")
    raise SystemExit(0)
if "DTEBX_P44_HMAC_V235" not in s:
    raise SystemExit(f"{path}: P4-4 not applied; not modified")

A = "systemctl switch-root /mnt /usr/sbin/init\n"
if s.count(A) != 1:
    raise SystemExit(f"{path}: switch-root anchor found {s.count(A)} times (expected 1); not modified")

B = f'''# {MARK}: close the firmware HMAC (and raw read) of key 1 before handing over to the rootfs.
#   Decision 2026-09-29 (案 B): if the lock cannot be confirmed, do not switch_root; reboot.
#   Success is judged by reading the status back (bit8 READ_LOCKED and bit11 HMAC_LOCKED), not by the exit code.
dtebx_key1_status() {{
  /usr/bin/rpi-fw-crypto get-key-status 1 2>/dev/null \\
    | /usr/bin/busybox sed -n 's/^Key 1 status: \\(0x[0-9a-fA-F]*\\).*/\\1/p'
}}
dtebx_lock_hmac() {{
  _t=1
  while [ "$_t" -le 5 ]; do
    /usr/bin/rpi-fw-crypto set-key-status 1 READ_LOCKED HMAC_LOCKED >/dev/null 2>&1
    _s="$(dtebx_key1_status)"
    if [ -n "$_s" ] && [ $(( _s & 0x900 )) -eq $(( 0x900 )) ]; then
      echo "[hmac-lock] key 1 locked (status ${{_s}}, attempt ${{_t}})"
      return 0
    fi
    echo "[hmac-lock] attempt ${{_t}}/5: key 1 status ${{_s:-unreadable}} (need bit8 and bit11)"
    _t=$((_t + 1))
    [ "$_t" -le 5 ] && /usr/bin/busybox sleep 1
  done
  return 1
}}
if ! dtebx_lock_hmac; then
  echo "FATAL(hmac-lock): could not close the firmware HMAC of key 1 after 5 attempts; NOT switching root. Rebooting in 30 s."
  {{ /usr/bin/busybox date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
     echo "FATAL(hmac-lock): key 1 status '$(dtebx_key1_status)' after 5 attempts (need bit8+bit11); boot refused, rebooting"
  }} >> /mnt/var/log/dtebx-hmac-lock-failed.log 2>/dev/null
  /usr/bin/busybox sync
  sleep 30 && reboot -f
  exit 1
fi

'''
s = s.replace(A, B + A, 1)
path.write_text(s)
print(f"patched: {path}")

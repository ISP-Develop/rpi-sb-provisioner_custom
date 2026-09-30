#!/usr/bin/env python3
# P4-8 (rpi-sb-provisioner 2.3.5 initramfs): publish the layer-C allowlist that is embedded in the initramfs.
#
# Why (2026-09-30): docs/42 :138 requires that the allowlist cannot be rewritten even by root ("装置上で一覧を
#   作り直す口は持たせない（root を取られても書き換えられない）"). Until now it was delivered by activation to a
#   writable LV (dfx_dtebx_docker/factory_default_0001/allowlist) and its signature was checked against a root CA
#   that is also root-writable (/usr/share/dfx/ca/rootCA.pem sits on the overlay, so writes go to the persistent
#   upper layer; /var/lib/dtebx/rootCA.pem is on lv_cert). Root could therefore replace both, persistently.
#   Now the signed list and its root CA are embedded in the initramfs (inside boot.img, K1 secure boot), so they
#   cannot be changed persistently. The checker (570-5, a host service) reads the copy published here.
#
# What: right before `systemctl switch-root` (after the P4-7 HMAC lock), copy /etc/dtebx/allowlist/{allowlist.tsv,
#   allowlist.sig.json, manifest.json, rootCA.pem} to /run/dtebx/allowlist/ (systemd moves /run into the new root at
#   switch-root), write STATUS (embedded|absent|copy-failed:<file>, the manifest version, the sha256 of allowlist.tsv),
#   and bind-remount the directory read-only. Root can still undo that for the current boot; what this guarantees is
#   that nothing survives a reboot (the peer judges with its own copy = axis 3).
#   Uses only busybox applets that are already in the initramfs, so the executables in the initramfs do not change
#   (the allowlist's initramfs rows change only by init_cryptroot.sh itself).
#   No list embedded or a copy/mount failure: say so on the console and in STATUS, and boot anyway (no fail-closed
#   at boot; 570-5 then reports UNVERIFIABLE).
#
# The list is embedded by build-initramfs-2.3.5.sh (3rd argument). It is not an executable, so embedding it does not
#   change any hash the list itself contains.
#
# Usage: python3 p4-8_initramfs_allowlist.py <path/to/init_cryptroot.sh>
# Idempotent (marker DTEBX_P48_ALLOWLIST_V235). Requires P4-7 (the block goes after the HMAC lock).
import sys
from pathlib import Path

MARK = "DTEBX_P48_ALLOWLIST_V235"
path = Path(sys.argv[1])
s = path.read_text()
if MARK in s:
    print(f"already patched: {path}")
    raise SystemExit(0)
if "DTEBX_P47_HMAC_LOCK_V235" not in s:
    raise SystemExit(f"{path}: P4-7 not applied; not modified")

A = "systemctl switch-root /mnt /usr/sbin/init\n"
if s.count(A) != 1:
    raise SystemExit(f"{path}: switch-root anchor found {s.count(A)} times (expected 1); not modified")

B = f'''# {MARK}: publish the allowlist embedded in this initramfs (K1-protected) to /run/dtebx/allowlist for 570-5.
#   docs/42 :138 (root cannot rewrite the list persistently). No list or a failure: report and boot anyway.
dtebx_publish_allowlist() {{
  _src=/etc/dtebx/allowlist
  _dst=/run/dtebx/allowlist
  /usr/bin/busybox mkdir -p "$_dst" || return 1
  if [ ! -s "$_src/allowlist.tsv" ] || [ ! -s "$_src/allowlist.sig.json" ] || [ ! -s "$_src/rootCA.pem" ]; then
    echo "absent" > "$_dst/STATUS"
    echo "[allowlist] no allowlist embedded in this initramfs (570-5 will report UNVERIFIABLE)"
    return 0
  fi
  for _f in allowlist.tsv allowlist.sig.json manifest.json rootCA.pem; do
    [ -e "$_src/$_f" ] || continue
    if ! /usr/bin/busybox cp "$_src/$_f" "$_dst/$_f"; then
      echo "copy-failed:$_f" > "$_dst/STATUS"
      return 1
    fi
    /usr/bin/busybox chmod 0444 "$_dst/$_f"
  done
  {{ echo "embedded"
     /usr/bin/busybox sed -n 's/.*"version": *"\\([^"]*\\)".*/\\1/p' "$_dst/manifest.json" 2>/dev/null | /usr/bin/busybox head -n 1
     /usr/bin/busybox sha256sum "$_dst/allowlist.tsv" | /usr/bin/busybox cut -d " " -f 1
  }} > "$_dst/STATUS"
  /usr/bin/busybox chmod 0444 "$_dst/STATUS"
  /usr/bin/busybox chmod 0555 "$_dst"
  if /usr/bin/busybox mount -o bind "$_dst" "$_dst" && /usr/bin/busybox mount -o remount,ro,bind "$_dst"; then
    echo "[allowlist] published $(/usr/bin/busybox head -n 2 "$_dst/STATUS" | /usr/bin/busybox tail -n 1) to $_dst (read-only)"
  else
    echo "[allowlist] published to $_dst, but the read-only bind failed (the copy is still K1-sourced)"
  fi
  return 0
}}
dtebx_publish_allowlist || echo "[allowlist] publishing failed (see /run/dtebx/allowlist/STATUS)"

'''
s = s.replace(A, B + A, 1)
path.write_text(s)
print(f"patched: {path}")

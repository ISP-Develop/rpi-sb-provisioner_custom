#!/bin/sh
# Build the rpi-sb-provisioner 2.3.5 cryptroot initramfs for prov2 (DEFORION P4-4 onward, 2026-09-29).
#
#   base    : work/extract_initramfs      (shared with the 2.0.4 build on prov; NEVER modified here)
#   overlay : work-2.3.5/overlay          (rpi-fw-crypto, librpifwcrypto, block-device-id, bookworm gnutls + deps)
#   patches : patches-2.3.5/p4-*_initramfs*.py, applied in name order to usr/bin/init_cryptroot.sh
#
# Run on the provisioning host as root, from a copy of this repository:
#   sudo sh build-initramfs-2.3.5.sh <repo-dir> <output-file>
# It only writes <output-file> and a scratch dir; installing into /var/lib/rpi-sb-provisioner is a separate step.
set -eu

REPO="${1:?repo dir}"
OUT="${2:?output file}"
WORK="$(mktemp -d /tmp/ird235.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

[ -d "${REPO}/work/extract_initramfs/usr/bin" ] || { echo "base tree not found under ${REPO}" >&2; exit 1; }
[ -d "${REPO}/work-2.3.5/overlay" ] || { echo "overlay not found under ${REPO}" >&2; exit 1; }

cp -a "${REPO}/work/extract_initramfs/." "${WORK}/"
cp -a "${REPO}/work-2.3.5/overlay/." "${WORK}/"

found=0
for p in "${REPO}"/patches-2.3.5/p4-*_initramfs*.py; do
    [ -f "$p" ] || continue
    found=1
    python3 "$p" "${WORK}/usr/bin/init_cryptroot.sh"
done
[ "$found" = 1 ] || { echo "no initramfs patches found" >&2; exit 1; }

sh -n "${WORK}/usr/bin/init_cryptroot.sh"
chmod 755 "${WORK}/usr/bin/init_cryptroot.sh" "${WORK}/usr/bin/rpi-fw-crypto" "${WORK}/usr/bin/block-device-id"
chown -R root:root "${WORK}"

( cd "${WORK}" && find . -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc 2>/dev/null ) \
    | zstd -q -z -19 -T0 -f -o "${OUT}"

echo "built: ${OUT}"
ls -l "${OUT}"
sha256sum "${OUT}"

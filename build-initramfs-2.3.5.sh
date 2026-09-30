#!/bin/sh
# Build the rpi-sb-provisioner 2.3.5 cryptroot initramfs for prov2 (DEFORION P4-4 onward, 2026-09-29).
#
#   base    : work/extract_initramfs      (shared with the 2.0.4 build on prov; NEVER modified here)
#   overlay : work-2.3.5/overlay          (rpi-fw-crypto, librpifwcrypto, block-device-id, bookworm gnutls + deps)
#   patches : patches-2.3.5/p4-*_initramfs*.py, applied in name order to usr/bin/init_cryptroot.sh
#
# Run on the provisioning host as root, from a copy of this repository:
#   sudo sh build-initramfs-2.3.5.sh <repo-dir> <output-file> [<allowlist-dir>]
#   <allowlist-dir>: signed allowlist.tsv / allowlist.sig.json / manifest.json + rootCA.pem to embed (P4-8).
# It only writes <output-file> and a scratch dir; installing into /var/lib/rpi-sb-provisioner is a separate step.
set -eu

REPO="${1:?repo dir}"
OUT="${2:?output file}"
ALLOWLIST="${3:-}"
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

# P4-8 (2026-09-30): embed the signed layer-C allowlist and its root CA (docs/42 :138). The list must have been built
#   from this same tree without the list (it lists executables only, so the embedded files do not change it).
if [ -n "${ALLOWLIST}" ]; then
    for f in allowlist.tsv allowlist.sig.json manifest.json rootCA.pem; do
        [ -s "${ALLOWLIST}/${f}" ] || { echo "allowlist dir lacks ${f}: ${ALLOWLIST}" >&2; exit 1; }
    done
    install -d -m 0755 "${WORK}/etc/dtebx/allowlist"
    for f in allowlist.tsv allowlist.sig.json manifest.json rootCA.pem; do
        install -m 0444 "${ALLOWLIST}/${f}" "${WORK}/etc/dtebx/allowlist/${f}"
    done
    echo "embedded allowlist: $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "${ALLOWLIST}/manifest.json" | head -n 1) ($(sha256sum "${ALLOWLIST}/allowlist.tsv" | cut -c1-16))"
else
    echo "WARNING: no allowlist embedded (3rd argument omitted); the unit will report the allowlist as absent" >&2
fi
chown -R root:root "${WORK}"

( cd "${WORK}" && find . -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc 2>/dev/null ) \
    | zstd -q -z -19 -T0 -f -o "${OUT}"

echo "built: ${OUT}"
ls -l "${OUT}"
sha256sum "${OUT}"

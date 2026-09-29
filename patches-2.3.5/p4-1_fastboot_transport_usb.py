#!/usr/bin/env python3
# P4-1 (rpi-sb-provisioner 2.3.5): pin the fastboot transport to USB.
#
# Successor of README §3.3 (2.0.4). Usage:
#   sudo python3 p4-1_fastboot_transport_usb.py [/usr/bin/rpi-sb-common.sh]
#
# Why: fastboot over TCP selects the target by IP address only, with no tie to
# the device serial. On 2026-08-15 (2.0.4) the rootfs `flash` went to another
# unit on the same network. 2.3.5 keeps control on USB in split mode but still
# routes `flash` to tcp:<addr> via FASTBOOT_TCP_FLASH_SPECIFIER, which is the
# same step. Every provisioner (sb/fde/naked/idp) takes
#   FLASH_SPECIFIER="${FASTBOOT_TCP_FLASH_SPECIFIER:-${FASTBOOT_DEVICE_SPECIFIER}}"
# so pinning both variables in setup_fastboot_and_id_vars() covers all of them.
#
# RPI_SB_PROVISIONER_FASTBOOT_TRANSPORT=auto restores the upstream behaviour
# (probe IPv6/IPv4 and use TCP when reachable). Anything else, including unset,
# means USB only: no IP query and no TCP connectivity probe.
#
# Idempotent (marker DTEBX_FASTBOOT_TRANSPORT_V235). Refuses to write if the
# expected upstream block is not found exactly once.
import sys
from pathlib import Path

MARK = "DTEBX_FASTBOOT_TRANSPORT_V235"
START = '    announce_start "Testing Fastboot IP connectivity"\n'
END = "    # Set TARGET_USB_PATH and TARGET_DEVICE_PATH based on TARGET_DEVICE_SERIAL\n"

path = Path(sys.argv[1] if len(sys.argv) > 1 else "/usr/bin/rpi-sb-common.sh")
s = path.read_text()

if MARK in s:
    print(f"already patched: {path}")
    raise SystemExit(0)

if s.count(START) != 1 or s.count(END) != 1:
    raise SystemExit(f"upstream block not found exactly once in {path} "
                     f"(start={s.count(START)}, end={s.count(END)}); not modified")

start = s.index(START)
end = s.index(END)
if end < start:
    raise SystemExit(f"block markers out of order in {path}; not modified")

block = s[start:end]
indented = "".join(("    " + l if l.strip() else l) for l in block.splitlines(keepends=True))

new = (
    f"    # {MARK}: fastboot transport selection (DEFORION P4-1).\n"
    '    # Default "usb": pin control AND flash to the USB serial; never query the\n'
    "    # device IP and never probe TCP. fastboot over TCP binds to an IP address\n"
    "    # with no association to the device serial, so with several targets on one\n"
    "    # network a flash can land on an unintended device.\n"
    "    # RPI_SB_PROVISIONER_FASTBOOT_TRANSPORT=auto restores the upstream logic.\n"
    '    if [ "${RPI_SB_PROVISIONER_FASTBOOT_TRANSPORT:-usb}" = "auto" ]; then\n'
    + indented +
    "    else\n"
    '        FASTBOOT_DEVICE_SPECIFIER="${TARGET_DEVICE_SERIAL}"\n'
    '        FASTBOOT_TCP_FLASH_SPECIFIER=""\n'
    '        log "Fastboot transport forced to USB for device ${TARGET_DEVICE_SERIAL} (control and flash)"\n'
    "    fi\n"
    "\n"
)

path.write_text(s[:start] + new + s[end:])
print(f"patched: {path}")

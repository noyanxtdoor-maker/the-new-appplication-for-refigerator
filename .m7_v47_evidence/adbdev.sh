#!/usr/bin/env bash
# VS16 M7 device helper — waits for the AUTHORIZED device to be ready, then
# execs adb against it by its mDNS TLS serial.
#
# Why: every tool call runs in a fresh shell, so the adb server restarts and the
# mDNS auto-connection needs several seconds to re-establish. Without this wait,
# commands fail with an empty device list.
#
# The serial is pinned to the authorized handset, so this helper can never act on
# a different device even if one is attached. If the mDNS transport is not yet
# up, the loop actively nudges discovery with `adb mdns services` (which
# re-triggers resolution) rather than idling.
#
# Usage:  bash .m7_v47_evidence/adbdev.sh shell getprop ro.serialno
#         bash .m7_v47_evidence/adbdev.sh install -r <apk>
set -u

ADB="C:/Users/sherl/AppData/Local/NextTransferFlutter/android-sdk/platform-tools/adb.exe"
SERIAL="adb-10620253B3004617-2m7ZVB._adb-tls-connect._tcp"
EXPECTED_SERIALNO="10620253B3004617"

"$ADB" start-server >/dev/null 2>&1

for i in $(seq 1 40); do
  if "$ADB" -s "$SERIAL" get-state >/dev/null 2>&1; then
    # Never act on a device we have not confirmed is the authorized handset.
    actual=$("$ADB" -s "$SERIAL" shell getprop ro.serialno 2>/dev/null | tr -d '\r')
    if [ "$actual" = "$EXPECTED_SERIALNO" ]; then
      exec "$ADB" -s "$SERIAL" "$@"
    fi
    echo "REFUSING: $SERIAL reports serialno '$actual', expected '$EXPECTED_SERIALNO'" >&2
    exit 2
  fi
  # Nudge mDNS re-resolution; a bare idle loop can miss the reconnect window.
  "$ADB" mdns services >/dev/null 2>&1
  sleep 2
done

echo "DEVICE NOT READY: $SERIAL did not come online within 80s" >&2
"$ADB" mdns services >&2
"$ADB" devices -l >&2
exit 1

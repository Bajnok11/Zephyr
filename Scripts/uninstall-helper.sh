#!/bin/sh
# Removes the Zephyr privileged helper. Fans go back to firmware control.

set -e

LABEL="com.bence.zephyr.helper"
DEST_DIR="/Library/Application Support/Zephyr"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if [ "$(id -u)" != "0" ]; then
    echo "hiba: root jogosultság szükséges" >&2
    exit 1
fi

launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$DEST_DIR"
rm -f /var/run/zephyr-helper.sock
rm -f /var/log/zephyr-helper.log

echo "kesz"

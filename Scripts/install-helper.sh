#!/bin/sh
# Installs the Zephyr privileged helper as a LaunchDaemon.
#
# Usage: sudo install-helper.sh <path-to-zephyr-helper> <uid-allowed-to-control>
#
# Everything this script does is reversible with uninstall-helper.sh.

set -e

SOURCE="$1"
OWNER_UID="$2"

LABEL="com.bence.zephyr.helper"
DEST_DIR="/Library/Application Support/Zephyr"
DEST="$DEST_DIR/zephyr-helper"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if [ -z "$SOURCE" ] || [ ! -f "$SOURCE" ]; then
    echo "error: helper binary not found: $SOURCE" >&2
    exit 1
fi

if [ -z "$OWNER_UID" ]; then
    echo "error: missing uid" >&2
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    echo "error: root privileges required" >&2
    exit 1
fi

# Stop any previous instance before replacing the binary underneath it.
# bootout is asynchronous: launchd can still be tearing the old job down when
# bootstrap runs below, and bootstrap then fails with "Input/output error (5)",
# leaving the machine with no helper at all. Wait for the job to actually go.
launchctl bootout "system/$LABEL" 2>/dev/null || true

i=0
while [ $i -lt 60 ]; do
    launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 0.2
    i=$((i + 1))
done

mkdir -p "$DEST_DIR"
cp "$SOURCE" "$DEST"
chown root:wheel "$DEST"
chmod 755 "$DEST"
chown root:wheel "$DEST_DIR"
chmod 755 "$DEST_DIR"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST</string>
        <string>--uid</string>
        <string>$OWNER_UID</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardErrorPath</key>
    <string>/var/log/zephyr-helper.log</string>
</dict>
</plist>
PLISTEOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# Retry anyway: a slow teardown can still race us, and failing here would
# leave fan control dead until the user works out they need to reinstall.
i=0
until launchctl bootstrap system "$PLIST" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -ge 15 ]; then
        echo "error: launchctl bootstrap failed for $LABEL" >&2
        exit 1
    fi
    sleep 0.3
done

# Give launchd a moment to start it and create the socket.
i=0
while [ $i -lt 25 ]; do
    if [ -S /var/run/zephyr-helper.sock ]; then
        echo "done"
        exit 0
    fi
    sleep 0.2
    i=$((i + 1))
done

echo "warning: the service started but the socket has not appeared yet" >&2
exit 0

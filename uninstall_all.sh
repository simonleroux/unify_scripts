#!/bin/sh
# STETNET Unifi_scripts Uninstaller
VERSION="1.0.1"

echo "⚠️ This will remove ALL STETNET services and scripts."
read -p "Are you sure? [y/N]: " confirm < /dev/tty
if [ "$confirm" != "y" ]; then
    echo "Aborting."
    exit 1
fi

# Services/Timers to remove
UNITS="automatic_update.service automatic_update.timer wg_failover.service wg_failover.timer wg_advisory.service"

echo "🔧 Stopping and disabling services..."
for unit in $UNITS; do
    systemctl stop "$unit" 2>/dev/null
    systemctl disable "$unit" 2>/dev/null
    rm -f "/etc/systemd/system/$unit"
done

systemctl daemon-reload
systemctl reset-failed

echo "📂 Removing data directories..."
rm -rf "/data/STETNET/automatic_update"
rm -rf "/data/STETNET/wg_failover"

echo "✅ All STETNET scripts and services removed."

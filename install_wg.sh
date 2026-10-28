#!/bin/sh
# WireGuard Failover Installer - Smart Auto-Detection Version
VERSION="1.0.9"

SERVICE_DIR="/data/STETNET/wg_failover"
SERVICE_NAME="wg_failover.service"
TIMER_NAME="wg_failover.timer"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
TIMER_PATH="/etc/systemd/system/$TIMER_NAME"

echo ""
echo "🔧 WireGuard Failover Installer (Auto-Detection)"
echo "================================================="
echo ""
echo "🔍 Detecting available WireGuard interfaces..."
AVAIL_INTERFACES=$(ip link show | grep -E '^[0-9]+: wg' | cut -d: -f2 | tr -d ' ')
echo ""
# Optional arguments (passed by the menu's update option) skip the prompts:
#   sh install_wg.sh [INTERFACE] [ENDPOINT_DOMAIN] [INTERVAL_SEC]
INTERFACE="$1"
ENDPOINT_DOMAIN="$2"
INTERVAL_SEC="$3"

echo "🔗 Step 1: WireGuard Interface"
if [ -z "$INTERFACE" ]; then
    if [ -n "$AVAIL_INTERFACES" ]; then
        echo "    Available: $AVAIL_INTERFACES"
    fi
    echo -n "    Enter interface name: "
    read INTERFACE < /dev/tty
fi

if [ -z "$INTERFACE" ]; then
    echo "❌ Error: Interface name is required."
    exit 1
fi

echo ""
echo "🔍 Extracting configuration from $INTERFACE..."
WG_CONFIG=$(wg showconf "$INTERFACE" 2>/dev/null)

if [ -z "$WG_CONFIG" ]; then
    echo "❌ Error: Could not read config. Is interface up?"
    exit 1
fi

PUBLIC_KEY=$(echo "$WG_CONFIG" | grep "PublicKey" | head -n1 | cut -d= -f2- | tr -d ' ')
ENDPOINT_PORT=$(echo "$WG_CONFIG" | grep "Endpoint" | head -n1 | cut -d: -f2 | tr -d ' ')

if [ -z "$PUBLIC_KEY" ]; then
    echo "❌ Error: Could not find peer public key."
    exit 1
fi

echo "✅ Found Peer Public Key: $PUBLIC_KEY"
echo "✅ Found Endpoint Port: $ENDPOINT_PORT"

echo ""
echo "🌐 Step 2: Endpoint Domain (e.g., vpn.example.com)"
if [ -z "$ENDPOINT_DOMAIN" ]; then
    read -p "    Enter domain: " ENDPOINT_DOMAIN < /dev/tty
fi

if [ -z "$ENDPOINT_DOMAIN" ]; then
    echo "❌ Error: Domain is required."
    exit 1
fi

echo ""
echo "⏱️  Step 3: Check Interval in seconds (default: 10, recommended: 10-30)"
if [ -z "$INTERVAL_SEC" ]; then
    read -p "    Enter interval: " INTERVAL_SEC < /dev/tty
fi
INTERVAL_SEC=${INTERVAL_SEC:-10}

echo ""
echo "🔧 Installing with:"
echo "    Interface: $INTERFACE"
echo "    Public Key: $PUBLIC_KEY"
echo "    Domain: $ENDPOINT_DOMAIN"
echo "    Port: $ENDPOINT_PORT"
echo "    Interval: $INTERVAL_SEC seconds"
echo ""

mkdir -p "$SERVICE_DIR"

echo "🔧 Writing WireGuard Failover script..."
cat << EOF > "$SERVICE_DIR/wireguard-dns-resolver.sh"
#!/bin/bash
# Version: $VERSION
# Dedicated WireGuard Dynamic Endpoint Resolver
# ==================== CONFIGURATION ====================
INTERFACE="$INTERFACE"
PUBLIC_KEY="$PUBLIC_KEY"
ENDPOINT_DOMAIN="$ENDPOINT_DOMAIN"
ENDPOINT_PORT="$ENDPOINT_PORT"
# =======================================================
export LC_ALL=C

# Look up the endpoint domain and realign WireGuard if its endpoint is stale.
# Returns 0 if healthy, 1 if the DNS lookup failed, 2 if the endpoint was changed.
check_and_realign() {
    # 1. Resolve the target domain name to get the expected IP
    # (parses the lines after "Name:" so both BIND and busybox nslookup output work)
    EXPECTED_IP=\$(nslookup "\$ENDPOINT_DOMAIN" 1.1.1.1 2>/dev/null | sed -n '/^Name/,\$p' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)

    # Safety check
    if [ -z "\$EXPECTED_IP" ]; then
        echo "Error: DNS resolution for \$ENDPOINT_DOMAIN failed. Skipping check."
        return 1
    fi

    # 2. Extract current remote IP
    CURRENT_IP=\$(wg show "\$INTERFACE" endpoints 2>/dev/null | grep -F "\$PUBLIC_KEY" | awk '{print \$2}' | cut -d: -f1)

    # 3. Compare IPs
    if [ "\$CURRENT_IP" = "\$EXPECTED_IP" ]; then
        echo "Tunnel is healthy."
        return 0
    fi
    echo "Tunnel is UNHEALTHY. DNS says \$EXPECTED_IP, WireGuard is pointing to \$CURRENT_IP."
    echo "Realigning endpoint to \$EXPECTED_IP:\$ENDPOINT_PORT..."
    wg set "\$INTERFACE" peer "\$PUBLIC_KEY" endpoint "\$EXPECTED_IP:\$ENDPOINT_PORT"
    wg syncconf "\$INTERFACE" <(wg showconf "\$INTERFACE")
    return 2
}

if [ "\$1" = "--once" ]; then
    check_and_realign
    exit 0
fi

check_and_realign
result=\$?
if [ "\$result" -eq 1 ]; then
    exit 1
fi

# The endpoint just changed: check every second for the next 30 seconds
if [ "\$result" -eq 2 ]; then
    echo "DNS change detected, checking every 1s for 30s..."
    i=0
    while [ "\$i" -lt 30 ]; do
        sleep 1
        check_and_realign
        i=\$((i + 1))
    done
fi
EOF

chmod +x "$SERVICE_DIR/wireguard-dns-resolver.sh"

echo "🔧 Creating systemd service..."
cat << EOF > "$SERVICE_DIR/$SERVICE_NAME"
[Unit]
Description=STETNET: WireGuard Dynamic Endpoint Resolver
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SERVICE_DIR/wireguard-dns-resolver.sh
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

echo "⏲️ Creating systemd timer with $INTERVAL_SEC second interval..."
cat << EOF > "$SERVICE_DIR/$TIMER_NAME"
[Unit]
Description=Run WireGuard failover check every $INTERVAL_SEC seconds

[Timer]
OnBootSec=10
OnUnitActiveSec=$INTERVAL_SEC
AccuracySec=1s
Unit=$SERVICE_NAME

[Install]
WantedBy=timers.target
EOF

if command -v nc >/dev/null 2>&1; then
    echo "📡 Writing failover advisory listener..."
    cat << 'EOF' > "$SERVICE_DIR/wg-advisory.sh"
#!/bin/bash
# Version: __VERSION__
# Listens for failover advisories from pfSense (UDP 50000, sent over the tunnel).
# A valid advisory starts 30 seconds of DNS checks, one per second.
# Packet: "failover <pfSense tunnel public key>" followed by a newline.

PORT=50000
INTERFACE="__INTERFACE__"
EXPECTED_LINE="failover __KEY__"
RESOLVER="__SERVICE_DIR__/wireguard-dns-resolver.sh"
WINDOW_SEC=30
window_end=0

# Listen on the UniFi's own address on the tunnel. pfSense sends advisories to that address.
ADDR=$(ip -4 -o addr show dev "$INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
if [ -z "$ADDR" ]; then
    echo "No IPv4 address on $INTERFACE yet, retrying"
    exit 1
fi
echo "Listening for failover advisories on $ADDR:$PORT"

# Read packets as they arrive. nc stays open for more datagrams, so a
# "head -n1" capture would wait for the next packet before acting on this one.
# The window runs inline: packets that arrive during it wait in the socket buffer
# and are then ignored, because they fall inside the window.
# The listener does not check the sender address. Packets only reach it through the
# tunnel from the peer that holds the pfSense key, and the key check applies on top.
# nc exits after each datagram on some builds, so restart it after every exit.
while true; do
    while read -r line; do
        # Strip a trailing carriage return. No tr stage here: tr buffers its output
        # on a pipe, so lines would never reach this loop while nc stays open.
        line=${line%$'\r'}
        if [ "$line" != "$EXPECTED_LINE" ]; then
            continue
        fi
        now=$(date +%s)
        if [ "$now" -lt "$window_end" ]; then
            continue
        fi
        window_end=$((now + WINDOW_SEC))
        echo "Failover advisory received, checking DNS every 1s for ${WINDOW_SEC}s"
        i=0
        while [ "$i" -lt "$WINDOW_SEC" ]; do
            bash "$RESOLVER" --once
            sleep 1
            i=$((i + 1))
        done
    done < <(nc -u -l -s "$ADDR" -p "$PORT")
    sleep 1
done

EOF
    sed -i "s|__KEY__|$PUBLIC_KEY|; s|__SERVICE_DIR__|$SERVICE_DIR|; s|__VERSION__|$VERSION|; s|__INTERFACE__|$INTERFACE|" "$SERVICE_DIR/wg-advisory.sh"
    chmod +x "$SERVICE_DIR/wg-advisory.sh"

    cat << EOF > "$SERVICE_DIR/wg_advisory.service"
[Unit]
Description=STETNET: WireGuard failover advisory listener
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=$SERVICE_DIR/wg-advisory.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    ln -sf "$SERVICE_DIR/wg_advisory.service" /etc/systemd/system/wg_advisory.service
else
    echo "⚠️ nc not found: failover advisory listener not installed."
fi

ln -sf "$SERVICE_DIR/$SERVICE_NAME" "$SERVICE_PATH"
ln -sf "$SERVICE_DIR/$TIMER_NAME" "$TIMER_PATH"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl enable "$TIMER_NAME"
systemctl start "$SERVICE_NAME"
systemctl start "$TIMER_NAME"
if [ -f /etc/systemd/system/wg_advisory.service ]; then
    systemctl enable wg_advisory.service
    systemctl restart wg_advisory.service
fi

echo "📄 Adding status.sh..."
cat << EOF > "$SERVICE_DIR/status.sh"
#!/bin/sh
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
NC="\033[0m"
echo ""
echo "\${YELLOW}🔍 STETNET WireGuard Failover Status\${NC}"
echo "Version: $VERSION"
echo "======================================="
echo ""
echo "📦 Service Status:"
if systemctl is-active --quiet wg_failover.service; then
  echo "\${GREEN}✅ wg_failover.service is active\${NC}"
else
  echo "\${YELLOW}ℹ️ wg_failover.service is inactive (normal)\${NC}"
fi
echo ""
echo "⏱️ Timer Status:"
if systemctl is-active --quiet wg_failover.timer; then
  echo "\${GREEN}✅ wg_failover.timer is active\${NC}"
else
  echo "\${RED}❌ wg_failover.timer is inactive\${NC}"
fi
echo ""
echo "🗓️ Next Timer Trigger:"
systemctl list-timers --all | grep wg_failover
echo ""
echo "📝 Last Service Run Log:"
last_run=\$(systemctl show -p ActiveEnterTimestamp --value wg_failover.service)
if [ -n "\$last_run" ] && [ "\$last_run" != "n/a" ]; then
    journalctl -u wg_failover.service --no-pager --since "\$last_run"
else
    echo "\${YELLOW}No logs found for the last execution.\${NC}"
fi
echo ""
echo "🔧 WireGuard Status:"
wg show
echo ""
EOF
chmod +x "$SERVICE_DIR/status.sh"

echo "✅ Installed WireGuard Failover check every $INTERVAL_SEC seconds."
echo "📊 Check status with: sh $SERVICE_DIR/status.sh"

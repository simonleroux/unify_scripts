#!/bin/sh
# WireGuard Failover Installer - Smart Auto-Detection Version
VERSION="1.0.1"

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

# 1. Resolve the target domain name to get the expected IP
# (parses the lines after "Name:" so both BIND and busybox nslookup output work)
EXPECTED_IP=\$(nslookup "\$ENDPOINT_DOMAIN" 1.1.1.1 2>/dev/null | sed -n '/^Name/,\$p' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)

# Safety check
if [ -z "\$EXPECTED_IP" ]; then
    echo "Error: DNS resolution for \$ENDPOINT_DOMAIN failed. Skipping check."
    exit 1
fi

# 2. Extract current remote IP
CURRENT_IP=\$(wg show "\$INTERFACE" endpoints 2>/dev/null | grep -F "\$PUBLIC_KEY" | awk '{print \$2}' | cut -d: -f1)

# 3. Compare IPs
if [ "\$CURRENT_IP" = "\$EXPECTED_IP" ]; then
    echo "Tunnel is healthy."
else
    echo "Tunnel is UNHEALTHY. DNS says \$EXPECTED_IP, WireGuard is pointing to \$CURRENT_IP."
    echo "Realigning endpoint to \$EXPECTED_IP:\$ENDPOINT_PORT..."
    wg set "\$INTERFACE" peer "\$PUBLIC_KEY" endpoint "\$EXPECTED_IP:\$ENDPOINT_PORT"
    wg syncconf "\$INTERFACE" <(wg showconf "\$INTERFACE")
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

ln -sf "$SERVICE_DIR/$SERVICE_NAME" "$SERVICE_PATH"
ln -sf "$SERVICE_DIR/$TIMER_NAME" "$TIMER_PATH"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl enable "$TIMER_NAME"
systemctl start "$SERVICE_NAME"
systemctl start "$TIMER_NAME"

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

#!/bin/sh
# Unifi_scripts Main Menu
VERSION="1.0.7"

REPO_URL="https://raw.githubusercontent.com/simonleroux/unify_scripts/refs/heads/main"
TMP_DIR="/tmp/stetnet_scripts"
CF_DIR="/data/STETNET/automatic_update"
WG_DIR="/data/STETNET/wg_failover"
mkdir -p "$TMP_DIR"

# Version written into a generated file ("# Version: x.y.z"), or a status word
installed_version() {
    if [ -f "$1" ]; then
        v=$(sed -n 's/^# Version: //p' "$1" | head -n1)
        echo "${v:-unknown (older install)}"
    else
        echo "not installed"
    fi
}

# VERSION as published on the server (GitHub) for one of the repo's files
server_version() {
    v=$(curl -fsSL --max-time 5 "$REPO_URL/$1" 2>/dev/null | tr -d '\r' | sed -n 's/^VERSION="\(.*\)"$/\1/p' | head -n1)
    echo "${v:-unavailable}"
}

# Installed version plus whether it matches the version on the server
version_status() {
    if [ "$1" = "not installed" ]; then
        echo "not installed"
        return
    fi
    server=$(server_version "$2")
    if [ "$server" = "unavailable" ]; then
        echo "$1 (server unreachable)"
    elif [ "$1" = "$server" ]; then
        echo "$1 (up to date)"
    else
        echo "$1 (update available: $server)"
    fi
}

show_menu() {
    echo "====================================="
    echo "       STETNET Unifi Scripts         "
    echo "====================================="
    echo "Menu:       $(version_status "$VERSION" menu.sh)"
    echo "Cloudflare: $(version_status "$(installed_version "$CF_DIR/automatic_update.sh")" install_cloudflare.sh)"
    echo "WireGuard:  $(version_status "$(installed_version "$WG_DIR/wireguard-dns-resolver.sh")" install_wg.sh)"
    echo "====================================="
    echo "1) Install Automatic Cloudflare/NextDNS Update"
    echo "2) Install WireGuard Failover"
    echo "3) Update installed scripts (keeps your settings)"
    echo "4) Pause installed scripts (disable timers)"
    echo "5) Resume installed scripts (enable timers)"
    echo "6) Check status"
    echo "7) Uninstall"
    echo "0) Exit"
    echo "====================================="
}

# Read the value of a VAR="value" line from a generated file
read_var() {
    sed -n "s/^$2=\"\(.*\)\"\$/\1/p" "$1" | head -n1
}

update_installed() {
    echo "Menu: installed $VERSION, server $(server_version menu.sh)"
    echo ""

    if [ -f "$CF_DIR/automatic_update.sh" ]; then
        echo "🔄 Updating Cloudflare/NextDNS update (keeping settings)..."
        echo "   installed: $(installed_version "$CF_DIR/automatic_update.sh"), server: $(server_version install_cloudflare.sh)"
        cf_host=$(read_var "$CF_DIR/automatic_update.sh" hostname)
        cf_nextdns=$(read_var "$CF_DIR/automatic_update.sh" nextdnsUrl)
        cf_token=$(read_var "$CF_DIR/automatic_update.sh" CF_API_TOKEN)
        cf_zone=$(read_var "$CF_DIR/automatic_update.sh" CF_ZONE_ID)
        cf_rec=$(read_var "$CF_DIR/automatic_update.sh" CF_RECORD_ID)
        cf_interval=$(sed -n 's/^OnCalendar=\*:0\/\([0-9]*\)$/\1/p' "$CF_DIR/automatic_update.timer" | head -n1)

        if [ -z "$cf_host" ] || [ -z "$cf_token" ] || [ -z "$cf_zone" ] || [ -z "$cf_rec" ]; then
            echo "❌ Could not read the saved Cloudflare settings, skipping."
        else
            curl -fsSL --max-time 60 "$REPO_URL/install_cloudflare.sh" -o "$TMP_DIR/install_cloudflare.sh" && sh "$TMP_DIR/install_cloudflare.sh" "${cf_interval:-5}" "$cf_host" "$cf_nextdns" "$cf_token" "$cf_zone" "$cf_rec"
        fi
        echo ""
    else
        echo "Cloudflare/NextDNS update is not installed, skipping."
    fi

    if [ -f "$WG_DIR/wireguard-dns-resolver.sh" ]; then
        echo "🔄 Updating WireGuard failover (keeping settings)..."
        echo "   installed: $(installed_version "$WG_DIR/wireguard-dns-resolver.sh"), server: $(server_version install_wg.sh)"
        wg_if=$(read_var "$WG_DIR/wireguard-dns-resolver.sh" INTERFACE)
        wg_domain=$(read_var "$WG_DIR/wireguard-dns-resolver.sh" ENDPOINT_DOMAIN)
        wg_interval=$(sed -n 's/^OnUnitActiveSec=\([0-9]*\)$/\1/p' "$WG_DIR/wg_failover.timer" | head -n1)

        if [ -z "$wg_if" ] || [ -z "$wg_domain" ]; then
            echo "❌ Could not read the saved WireGuard settings, skipping."
        else
            curl -fsSL --max-time 60 "$REPO_URL/install_wg.sh" -o "$TMP_DIR/install_wg.sh" && sh "$TMP_DIR/install_wg.sh" "$wg_if" "$wg_domain" "${wg_interval:-10}"
        fi
    else
        echo "WireGuard failover is not installed, skipping."
    fi
}

# Pause: stop the timer and service, then remove only their enable links so they
# stay off after a reboot. Do NOT use "systemctl disable": the installer's unit files
# live in /etc/systemd/system as symlinks, and disable deletes those too.
pause_units() {
    systemctl stop "$1" "$2" && \
        rm -f "/etc/systemd/system/timers.target.wants/$1" "/etc/systemd/system/multi-user.target.wants/$2" && \
        systemctl daemon-reload
}

# Resume: re-create the enable links and start the timer
resume_units() {
    systemctl enable "$2" "$1" && systemctl start "$1"
}

# The advisory listener is optional (only installed if nc is available), so these skip when it's missing
pause_advisory() {
    [ -f /etc/systemd/system/wg_advisory.service ] || return 0
    systemctl stop wg_advisory.service && \
        rm -f /etc/systemd/system/multi-user.target.wants/wg_advisory.service && \
        systemctl daemon-reload
}

resume_advisory() {
    [ -f /etc/systemd/system/wg_advisory.service ] || return 0
    systemctl enable wg_advisory.service && systemctl start wg_advisory.service
}

pause_installed() {
    if [ -f "$CF_DIR/automatic_update.sh" ]; then
        if pause_units automatic_update.timer automatic_update.service; then
            echo "⏸️  Cloudflare/NextDNS update paused."
        else
            echo "❌ Could not pause the Cloudflare/NextDNS update."
        fi
    else
        echo "Cloudflare/NextDNS update is not installed, skipping."
    fi

    if [ -f "$WG_DIR/wireguard-dns-resolver.sh" ]; then
        if pause_units wg_failover.timer wg_failover.service && pause_advisory; then
            echo "⏸️  WireGuard failover paused."
        else
            echo "❌ Could not pause the WireGuard failover."
        fi
    else
        echo "WireGuard failover is not installed, skipping."
    fi
}

resume_installed() {
    if [ -f "$CF_DIR/automatic_update.sh" ]; then
        if resume_units automatic_update.timer automatic_update.service; then
            echo "▶️  Cloudflare/NextDNS update resumed."
        else
            echo "❌ Could not resume the Cloudflare/NextDNS update."
        fi
    else
        echo "Cloudflare/NextDNS update is not installed, skipping."
    fi

    if [ -f "$WG_DIR/wireguard-dns-resolver.sh" ]; then
        if resume_units wg_failover.timer wg_failover.service && resume_advisory; then
            echo "▶️  WireGuard failover resumed."
        else
            echo "❌ Could not resume the WireGuard failover."
        fi
    else
        echo "WireGuard failover is not installed, skipping."
    fi
}

# Show the status script of each installed component
status_installed() {
    if [ -f "$CF_DIR/status.sh" ]; then
        sh "$CF_DIR/status.sh"
    else
        echo "Cloudflare/NextDNS update is not installed, skipping."
    fi

    if [ -f "$WG_DIR/status.sh" ]; then
        sh "$WG_DIR/status.sh"
    else
        echo "WireGuard failover is not installed, skipping."
    fi
}

while true; do
    show_menu
    echo -n "Select an option [0-7]: "
    read choice < /dev/tty
    case $choice in
        1)
            # Interactive installation for Cloudflare/NextDNS
            echo ""
            echo "📝 Cloudflare/NextDNS Configuration"
            echo "===================================="
            echo ""
            echo "⏱️  INTERVAL (minutes): How often to check IP (e.g., 5)"
            echo -n "    Enter interval [default: 5]: "
            read INTERVAL < /dev/tty
            INTERVAL=${INTERVAL:-5}
            echo ""
            echo "🌐 HOSTNAME: Your fully qualified domain name (e.g., home.example.com)"
            echo -n "    Enter hostname: "
            read HOSTNAME < /dev/tty
            echo ""
            echo "🔵 NEXTDNS URL: Your update link (optional, e.g., https://link-XXXXX.nextdns.io/YYYY)"
            echo -n "    Enter NextDNS URL (leave blank to skip): "
            read NEXTDNS_URL < /dev/tty
            echo ""
            echo "🟠 CLOUDFLARE API TOKEN: Get from https://dash.cloudflare.com/profile/api-tokens (DNS:Edit)"
            echo -n "    Enter API Token: "
            read CF_TOKEN < /dev/tty
            echo ""
            echo "🟠 ZONE ID: From Cloudflare Domain Overview (right sidebar)"
            echo -n "    Enter Zone ID: "
            read CF_ZONE < /dev/tty
            echo ""
            echo "🟠 RECORD ID: From Cloudflare DNS Records (specific A record for hostname)"
            echo -n "    Enter Record ID: "
            read CF_REC < /dev/tty
            echo ""
            echo "🚀 Installing with your configuration..."
            echo ""
            curl -fsSL --max-time 60 "$REPO_URL/install_cloudflare.sh" -o "$TMP_DIR/install_cloudflare.sh" && sh "$TMP_DIR/install_cloudflare.sh" "$INTERVAL" "$HOSTNAME" "$NEXTDNS_URL" "$CF_TOKEN" "$CF_ZONE" "$CF_REC"
            echo ""
            echo ""
            echo -n "Press Enter to return to menu..."
            read dummy < /dev/tty
            ;;
        2)
            curl -fsSL --max-time 60 "$REPO_URL/install_wg.sh" -o "$TMP_DIR/install_wg.sh" && sh "$TMP_DIR/install_wg.sh"
            echo ""
            echo ""
            echo -n "Press Enter to return to menu..."
            read dummy < /dev/tty
            ;;
        3)
            update_installed
            echo ""
            echo ""
            echo -n "Press Enter to return to menu..."
            read dummy < /dev/tty
            ;;
        4)
            pause_installed
            echo ""
            echo ""
            echo -n "Press Enter to return to menu..."
            read dummy < /dev/tty
            ;;
        5)
            resume_installed
            echo ""
            echo ""
            echo -n "Press Enter to return to menu..."
            read dummy < /dev/tty
            ;;
        6)
            status_installed
            echo ""
            echo -n "Press Enter to return to menu..."
            read dummy < /dev/tty
            ;;
        7)
            curl -fsSL --max-time 60 "$REPO_URL/uninstall_all.sh" -o "$TMP_DIR/uninstall_all.sh" && sh "$TMP_DIR/uninstall_all.sh"
            echo ""
            echo ""
            echo -n "Press Enter to return to menu..."
            read dummy < /dev/tty
            ;;
        0)
            exit 0
            ;;
        *)
            echo "Invalid option."
            ;;
    esac
done

# STETNET Unifi Scripts

Scripts for UniFi gateways (UCG Ultra, etc.) that keep remote access working when the connection has a dynamic or CGNAT public IP:

- **Automatic Cloudflare/NextDNS update**: keeps a Cloudflare A record and an optional NextDNS link pointed at the current public IP.
- **WireGuard failover**: checks a WireGuard peer's endpoint against DNS and re-points it when the DNS record changes.

Designed for UniFi OS 4.x and later.

---

## ✅ Features

- 🛡️ Only updates DNS when the current public IP differs from what DNS resolves to
- 🔁 Runs once at boot and then on a fixed interval, via `systemd` service and timer
- 🧩 Interactive menu for installing, uninstalling, and checking status
- 🧼 Each script keeps its files in its own folder under `/data/STETNET/`
- 🔄 Supports Cloudflare DNS (A records) and NextDNS update links

---

## 🚀 Quick Start (Menu)

Run the menu on the gateway over SSH:

```bash
curl -fsSL https://raw.githubusercontent.com/simonleroux/unify_scripts/refs/heads/main/menu.sh | sh
```

```
1) Install Automatic Cloudflare/NextDNS Update
2) Install WireGuard Failover
3) Update installed scripts (keeps your settings)
4) Pause installed scripts (disable timers)
5) Resume installed scripts (enable timers)
6) Check status
7) Uninstall
0) Exit
```

---

## 🌐 Cloudflare / NextDNS Update

### Before you start

You need:

- **Hostname**: the fully qualified name to update, e.g. `home.example.com`. The DNS record must already exist as an A record.
- **Cloudflare API token** with *Zone → DNS → Edit* permission. Create one at https://dash.cloudflare.com/profile/api-tokens
- **Zone ID**: shown in the right sidebar of the domain's Overview page.
- **Record ID**: the ID of the A record for the hostname, from the DNS Records page.
- **NextDNS update URL** (optional): e.g. `https://link-XXXXX.nextdns.io/YYYY`. Leave blank to skip NextDNS.

### Install

Use the menu (option 1), or run the installer directly:

```bash
curl -fsSL https://raw.githubusercontent.com/simonleroux/unify_scripts/refs/heads/main/install_cloudflare.sh | sh -s -- [INTERVAL] [HOSTNAME] [NEXTDNS_URL] [CF_TOKEN] [CF_ZONE_ID] [CF_RECORD_ID]
```

| Argument | Description | Default |
|---|---|---|
| `INTERVAL` | Minutes between checks | `5` |
| `HOSTNAME` | Hostname to keep updated | (required) |
| `NEXTDNS_URL` | NextDNS update link | (blank = skip) |
| `CF_TOKEN` | Cloudflare API token | (required) |
| `CF_ZONE_ID` | Cloudflare zone ID | (required) |
| `CF_RECORD_ID` | Cloudflare record ID | (required) |

Example (every 5 minutes):

```bash
curl -fsSL https://raw.githubusercontent.com/simonleroux/unify_scripts/refs/heads/main/install_cloudflare.sh | sh -s -- 5 "home.example.com" "https://link-XXXXX.nextdns.io/YYYY" "your_cf_token" "zone_id" "record_id"
```

### How it works

Each run:

1. Gets the current public IP from `api.ipify.org`.
2. Resolves the hostname through `1.1.1.1`.
3. If the two differ, updates NextDNS (if configured) and then the Cloudflare A record.

### Files

Installed to `/data/STETNET/automatic_update/`:

- `automatic_update.sh`: the update script. It contains your API token, so restrict it: `chmod 600 /data/STETNET/automatic_update/automatic_update.sh`
- `automatic_update.service` / `automatic_update.timer`: systemd units (symlinked into `/etc/systemd/system/`)
- `status.sh`: health check (see below)

---

## 🔀 WireGuard Failover

Menu option 2 installs a check for a WireGuard peer whose endpoint is a domain name. The check resolves the domain and, if the peer's endpoint IP no longer matches, sets the peer's endpoint to the new IP and restarts the interface.

You need:

- The WireGuard interface name (e.g. `wgclt2`). The interface must be up, because the installer reads the peer's public key and endpoint from it.
- The endpoint domain (e.g. `vpn.example.com`).
- A check interval in seconds (default `10`; `10`–`30` recommended).

Installed to `/data/STETNET/wg_failover/`:

- `wireguard-dns-resolver.sh`: the check script
- `wg_failover.service` / `wg_failover.timer`: systemd units
- `status.sh`: health check

---

## 🧼 Uninstallation

Remove the Cloudflare/NextDNS update only:

```bash
curl -fsSL https://raw.githubusercontent.com/simonleroux/unify_scripts/refs/heads/main/uninstall.sh | sh
```

Remove **all** STETNET services and scripts (asks for confirmation):

```bash
curl -fsSL https://raw.githubusercontent.com/simonleroux/unify_scripts/refs/heads/main/uninstall_all.sh | sh
```

Or use menu option 7.

---

## 🔄 Updating

To get the latest scripts without re-entering your settings, use menu option 3. It re-downloads the installers and re-runs them with the values already saved on the gateway:

- **Cloudflare/NextDNS:** hostname, NextDNS URL, API token, zone ID, record ID, and interval are read from `automatic_update.sh` and `automatic_update.timer`.
- **WireGuard:** interface, endpoint domain, and interval are read from `wireguard-dns-resolver.sh` and `wg_failover.timer`.

Only components that are already installed are updated. Each one is skipped if its settings can't be read.

## ⏸️ Pausing and Resuming

To turn off the automatic checks temporarily without uninstalling:

- **Menu option 4 (pause):** disables and stops the timers and services for Cloudflare/NextDNS and WireGuard. They stay off after a reboot.
- **Menu option 5 (resume):** enables the timers and services again and starts the timers.

Pausing does not delete or change any settings.

---

## 🩺 Check Health

```bash
sh /data/STETNET/automatic_update/status.sh   # Cloudflare/NextDNS update
sh /data/STETNET/wg_failover/status.sh        # WireGuard failover
```

These show:

- Service and timer status
- Next scheduled timer trigger
- Logs from the most recent service run

---

## 🛠️ Systemd Controls

Replace `automatic_update` with `wg_failover` for the WireGuard check.

```bash
# Run the update immediately
systemctl start automatic_update.service

# View service status
systemctl status automatic_update.service

# Stop/start the periodic timer
systemctl stop automatic_update.timer
systemctl start automatic_update.timer

# View timer schedule
systemctl list-timers --all | grep automatic_update
```

---

## 📝 License

This project is licensed under the [MIT License](LICENSE).

---

## 🤝 Contributing

Contributions are welcome! Feel free to fork the repository, submit pull requests, or suggest improvements.

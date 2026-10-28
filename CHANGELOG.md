# Changelog

Every change to the scripts is recorded here. Each script has a `VERSION` line; bump it when you change that file and note the new version in the entry below.

## Unreleased

### Added
- `install_wg.sh`: a failover advisory listener (`wg_advisory.service`) on UDP 50000, bound to the UniFi's tunnel address. A valid `failover <pfSense public key>` packet starts 30 seconds of DNS checks, one per second. Repeat packets inside the window are ignored. It is only installed if `nc` is available on the router. It does not check the packet's source address; WireGuard peer authentication and the key check apply.
- The menu header shows whether the menu and the installed Cloudflare/NextDNS and WireGuard components are up to date.
- Menu option 3 updates installed scripts and keeps their saved settings.
- Menu options 4 and 5 pause and resume the Cloudflare/NextDNS and WireGuard timers. Pausing keeps the unit files and only removes the enable links.
- `VERSION` in every script. The menu shows the installed and server versions, and generated scripts and `status.sh` record theirs.
- `CHANGELOG.md` (this file).
- Menu option 6 shows the status of the installed Cloudflare/NextDNS and WireGuard components.

### Changed
- `install_wg.sh`: the resolver has a `--once` mode for single checks. Pause, resume, and uninstall also handle the advisory listener. `uninstall_all.sh` removes it.
- `install_wg.sh`: after the resolver detects a DNS change, it checks every second for the next 30 seconds, so the tunnel realigns faster. The failover service has `TimeoutStartSec=120` to allow the longer run.
- `menu.sh`: menu order is now Update (3), Pause (4), Resume (5), Check status (6), Uninstall (7), Exit (0), with names matching the pfSense menu.
- `menu.sh`: exit the menu with option 0 (was 7). Options 1 to 6 are unchanged.
- `install_cloudflare.sh`: the public IP and DNS lookup must both return a value, or the run is skipped.
- `install_cloudflare.sh`: DNS lookup works with both BIND and busybox `nslookup` output. The current IP is checked against every A record.
- `install_cloudflare.sh`: the NextDNS call is skipped when no URL is set.
- `install_cloudflare.sh`: ipify uses `https://` and all `curl` calls have `--max-time` timeouts.
- `install_wg.sh`: the endpoint lookup uses the same parser as the Cloudflare script, so it works with busybox output.
- `install_wg.sh`: the resolver re-applies the config with `wg syncconf` instead of bringing the interface down and up.
- `install_wg.sh`: takes `INTERFACE`, `ENDPOINT_DOMAIN`, and `INTERVAL_SEC` as arguments and only prompts for missing values.
- `install_wg.sh`: the example domain in the prompt is `vpn.example.com`.
- `menu.sh`: downloads use `--max-time 60`.
- `README.md`: rewritten for the current repo, menu, update, and pause/resume.

### Fixed
- `install_wg.sh`: the public key parse kept the trailing `=`, so the failover can realign the endpoint.
- `install_wg.sh`: the failover timer has `AccuracySec=1s`. Without it, systemd can run the check up to a minute late.
- Pause no longer deletes the unit files; it used `systemctl disable`, which removed the `/etc/systemd/system` symlinks.

### Known issues (not yet fixed)
- `install_cloudflare.sh`: the Cloudflare API response is used as a printf format string.
- Input is not validated (missing arguments, non-numeric intervals), and the final "Installed" message prints even if a step failed.
- The Cloudflare API token is stored in `automatic_update.sh` with default file permissions.
- `install_cloudflare.sh`: `systemctl daemon-reexec` is unnecessary.
- No `.gitattributes`, so Windows checkouts get CRLF line endings that break `sh` on the router.

# Configuration reference

All configuration is read from environment variables, loaded from `/etc/zenvps/env` (or `.env` for local development). The file has mode `0600` and is owned by root.


## Required

| Variable | Description |
|---|---|
| `DISCORD_TOKEN` | Bot token from <https://discord.com/developers/applications>. 50+ chars, alphanumeric + `.` `-` `_`. |
| `OWNER_IDS` | Comma-separated Discord user IDs of the bot owners (full privileges, including the ability to add/remove admins). At least one is required. |

## Recommended

| Variable | Default | Description |
|---|---|---|
| `ADMIN_IDS` | (empty) | Comma-separated Discord user IDs of admins. Can manage all VPS, ban users, run `/admin` commands, but cannot manage other admins. |
| `ADMIN_ROLE_IDS` | (empty) | Comma-separated Discord role IDs. Anyone carrying one of these roles is treated as an admin (per-guild). |
| `GUILD_ID` | (empty) | Restrict slash-command sync to one guild. Leaves blank for global sync (caches for up to 1 hour). |

## Branding

| Variable | Default | Description |
|---|---|---|
| `BRAND_NAME` | `ZenVPS` | Display name used in embeds, MOTD, and log messages. Must match `^[A-Za-z0-9][A-Za-z0-9_\-. ]{0,62}$`. |
| `WELCOME_MESSAGE` | `Welcome to your ZenVPS instance.` | Written to `/etc/motd` inside each VPS container. |
| `EMBED_COLOR` | `#5865F2` | Hex color for embeds (must be `#RRGGBB`). |
| `STATUS_TEXT` | `VPS Manager` | Discord presence text (Watching …). |

## Paths

| Variable | Default | Description |
|---|---|---|
| `DATA_DIR` | `/var/lib/zenvps` | Database, keys, temp files. |
| `LOG_DIR` | `/var/log/zenvps` | Log files. |
| `BACKUP_DIR` | `/var/lib/zenvps/backups` | gzipped JSON snapshots. |
| `TEMP_DIR` | `/var/lib/zenvps/temp` | Temporary files (cleaned on restart). |

## Limits

| Variable | Default | Description |
|---|---|---|
| `MAX_VPS_PER_USER` | `2` | Max VPS a single Discord user can own. |
| `MAX_TOTAL_VPS` | `50` | Total VPS on this node. New deploys fail when reached. |
| `DEFAULT_MEMORY_MB` | `1024` | Memory allocated to a new VPS if user doesn't specify. |
| `DEFAULT_CPU_CORES` | `1.0` | CPU cores allocated to a new VPS. |
| `DEFAULT_DISK_MB` | `10240` | Disk quota (informational; not enforced without devicemapper). |
| `MAX_MEMORY_MB` | `8192` | Upper bound on memory a user can request. |
| `MAX_CPU_CORES` | `4.0` | Upper bound on CPU a user can request. |
| `MAX_DISK_MB` | `51200` | Upper bound on disk a user can request. |

## Remote access

| Variable | Default | Description |
|---|---|---|
| `ENABLE_TMATE` | `true` | In-container tmate SSH session over tmate.io relay. Works behind NAT. |
| `ENABLE_SSHX` | `true` | sshx.io terminal sharing (HTTPS-based, collaborative). |
| `ENABLE_SERVEO` | `true` | serveo.net HTTP and TCP forwarding (`/ssh serveo-http`, `/ssh serveo-tcp`). |
| `ENABLE_HOST_SSH` | `false` | Per-VPS SSH keypair + host port forward. Requires a publicly reachable host IP. |
| `HOST_SSH_BASE_PORT` | `22000` | First port in the host-SSH allocation range. |
| `HOST_SSH_MAX_PORT` | `22999` | Last port in the host-SSH allocation range (1000 simultaneous VPS). |
| `SSHX_ENDPOINT` | `sshx.io` | SSHX relay endpoint (rarely needs changing). |

## Container isolation

| Variable | Default | Description |
|---|---|---|
| `DOCKER_NETWORK` | `bridge` | Docker network for VPS containers. |
| `CONTAINER_DEFAULT_OS` | `ubuntu:22.04` | Default image if user doesn't specify in `/deploy`. |
| `CONTAINER_LABEL` | `zenvps.managed` | Docker label applied to every managed container. Used for `docker ps --filter`. |
| `DROP_ALL_CAPS` | `true` | If true, `--cap-drop=ALL` is added and only `EXTRA_CAPS` are added back. |
| `EXTRA_CAPS` | `CHOWN,SETUID,SETGID,NET_BIND_SERVICE` | Comma-separated list of capabilities to add back when `DROP_ALL_CAPS=true`. |

**Never** set `EXTRA_CAPS=ALL` or override `DROP_ALL_CAPS=false` unless you understand the security implications. The original V4 bot ran containers with `--privileged --cap-add=ALL`, which is equivalent to giving the container root access to the host.

## Anti-abuse

| Variable | Default | Description |
|---|---|---|
| `ENABLE_ANTI_ABUSE` | `true` | Run the container-level process scanner. |
| `MINER_CHECK_INTERVAL_SEC` | `300` | Seconds between scans of each running VPS. |
| `MINER_STRIKE_LIMIT` | `3` | Number of strikes before a VPS is suspended. Strikes decay by 1 every 24h of clean operation. |
| `CPU_THROTTLE_PERCENT` | `200` | Default CPU limit applied to every container (200% = 2 full cores). |
| `EGRESS_FILTER_ENABLED` | `false` | If true, run `/var/lib/zenvps/egress-filter.sh install` to install nftables/iptables rules blocking 50+ known mining pool domains. |

The host-level `anti-abuse.sh` script runs as a separate systemd service independently of `ENABLE_ANTI_ABUSE`. To stop it: `sudo systemctl stop zenvps-anti-abuse.service`.

## Reliability

| Variable | Default | Description |
|---|---|---|
| `WATCHDOG_INTERVAL_SEC` | `60` | Seconds between watchdog health checks. |
| `WATCHDOG_FAILURE_THRESHOLD` | `3` | Consecutive failures before the watchdog restarts the bot. |
| `AUTO_RECONNECT` | `true` | discord.py auto-reconnect on WebSocket drop. |

## Logging

| Variable | Default | Description |
|---|---|---|
| `LOG_LEVEL` | `INFO` | One of `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL`. |
| `LOG_KEEP_DAYS` | `14` | Days to retain daily-rotated log files. |
| `ENABLE_SETUP_WIZARD` | `true` | Run the interactive wizard on first install. |

## Log files

| File | Contents |
|---|---|
| `zenvps.log` | All INFO+ records. |
| `zenvps-error.log` | ERROR+ records only. |
| `zenvps-audit.log` | Audit events (bot_started, bot_stopped, VPS lifecycle). |
| `zenvps-security.log` | Security events (miners detected, suspensions, bans). |
| `zenvps-install.log` | Installer / repair / uninstall actions. |

All logs are scrubbed of secrets (Discord tokens, passwords, SSH private keys) by the logger filter before being written.

## Environment variable precedence

1. Real environment variables (set in the shell that launches the bot)
2. `/etc/zenvps/env` (loaded by systemd's `EnvironmentFile=`)
3. `.env` in the current working directory (local dev only)

Higher numbers win — a real env var overrides the systemd file.

## Validation

Every value is validated on startup. Invalid values cause the bot to exit with a clear error message pointing at the offending variable. For example:

```
❌ Configuration error: MAX_VPS_PER_USER must be at least 1
   See /etc/zenvps.env (or .env) and the docs/CONFIG.md file.
```

There is no "silent default" for an invalid value — the bot refuses to start rather than running with a broken configuration.

## Changing configuration at runtime

Most settings require a restart:

```bash
sudo zenvps restart
```

A few are picked up live:

- `MAX_VPS_PER_USER`, `MAX_TOTAL_VPS`, `MAX_*` limits → read on each `/deploy` invocation
- `MINER_CHECK_INTERVAL_SEC`, `MINER_STRIKE_LIMIT` → read at the next scan interval
- All Discord/branding settings → require restart

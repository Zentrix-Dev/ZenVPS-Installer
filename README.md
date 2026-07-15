# ZenVPS Installer

> **Made by [ZentrixDev](https://github.com/ZentrixDev)**

This package contains the installer for the ZenVPS Discord bot — a hardened, modular Python bot for managing Docker-based VPS containers on Ubuntu LTS and Debian stable.

This package contains **only the installer**. The bot source code is in the companion `ZenVPS-Files-v1.0.0.zip` package.

## What's inside

```
ZenVPS-Installer/
├── README.md              ← this file
├── LICENSE                ← MIT
├── install.sh             ← main installer entry point
├── lib/
│   └── helpers.sh         ← all installer logic (deps, docker, service, wizard, …)
├── systemd/               ← systemd unit files (copied to /etc/systemd/system/)
│   ├── zenvps.service
│   ├── zenvps-watchdog.service
│   ├── zenvps-watchdog.timer
│   └── zenvps-anti-abuse.service
├── logrotate/
│   └── zenvps             ← daily rotation, 14-day retention
├── scripts/               ← runtime helper scripts
│   ├── zenvps             ← CLI management tool → /usr/local/bin/zenvps
│   ├── anti-abuse.sh      ← host-level miner killer (separate systemd service)
│   └── egress-filter.sh   ← nftables/iptables blocklist for mining pools
├── docker/                ← VPS-image Dockerfiles
│   ├── Dockerfile.ubuntu  ← hardened Ubuntu 22.04 image
│   └── Dockerfile.debian  ← hardened Debian 12 image
└── docs/                  ← full documentation
    ├── INSTALL.md
    ├── CONFIG.md
    ├── SECURITY.md
    ├── PERFORMANCE.md
    ├── ARCHITECTURE.md
    └── BUGS_FIXED.md
```

## Prerequisites

- A Linux host running **Ubuntu 20.04 / 22.04 / 24.04 LTS** or **Debian 11 / 12**
- Root access (the installer uses `sudo`)
- Internet access (the installer `git clone`s the bot source from GitHub by default)
- A Discord bot token from <https://discord.com/developers/applications>
- Your Discord user ID (right-click yourself in Discord → Copy ID)

The installer refuses to run on any other OS (CentOS, Fedora, Alpine, Arch, etc.).

## Quick start

The installer is self-sufficient — it `git clone`s the bot source from GitHub for you. You only need the installer ZIP.


## One Click Installation
```
apt update -y && apt upgrade -y && apt install git -y && git clone https://github.com/Zentrix-Dev/ZenVPS-Installer.git && sudo bash ZenVPS-Installer/install.sh install
```

## Manual Installation
```bash
# 1. Extract just the installer
unzip ZenVPS-Installer-v1.0.0.zip

# 2. Run it
sudo bash ZenVPS-Installer/install.sh install

# 3. The installer will:
#    • Install git, Python 3, Docker, and system dependencies
#    • Ask: "Where should I get the ZenVPS source code from?"
#        1) Git clone from GitHub (default — recommended)
#        2) Use a local copy (if you extracted ZenVPS-Files-v1.0.0.zip too)
#    • Build the Ubuntu and Debian VPS Docker images
#    • Set up the systemd service, watchdog, logrotate, and CLI tool
#    • Run the interactive setup wizard, which asks for:
#        • Discord bot token          (required)
#        • Your Discord user ID       (required — becomes the bot owner)
#        • Discord server (guild) ID  (recommended — for instant slash-command sync)
#        • Discord server invite link (optional — shown in /about and /help)
#        • Brand name                 (optional — default: ZenVPS)
#        • Max VPS per user           (optional — default: 2)
#    • Start the bot

# 4. Check it's running
sudo zenvps status
```

## Where does the bot source come from?

By default, the installer `git clone`s from:

```
https://github.com/ZentrixDev/ZenVPS-Files.git
```

You can override this in three ways:

1. **Environment variable** (for non-interactive installs):
   ```bash
   sudo ZENVPS_REPO_URL=https://github.com/your-fork/ZenVPS-Files.git bash install.sh install
   ```

2. **Interactive prompt** — when you run `install.sh install` in a TTY, the installer asks you to choose between git-clone and local-copy.

3. **Local copy** — if you've extracted `ZenVPS-Files-v1.0.0.zip` next to the installer (or set `ZENVPS_SRC=/path/to/python`), you can pick "Use a local copy" when prompted. This is useful for offline installs.

The `install.sh update` command later does a `git pull` on the same repo to fetch the latest version automatically.

## All installer commands

| Command | Description |
|---|---|
| `install` | Fresh install (with interactive setup wizard) |
| `install --yes` | Same as `install` but skips confirmation prompts |
| `update` | Re-copy source, reinstall deps, rebuild Docker images, restart |
| `uninstall` | Stop service, remove files (preserves data + backups + config) |
| `repair` | Reinstall deps and re-sync service files (keeps your data) |
| `status` | Show service status, version, and config sanity |
| `wizard` | Re-run the interactive setup wizard |

Examples:

```bash
sudo bash install.sh install
sudo bash install.sh install --yes      # no prompts (CI)
sudo bash install.sh update
sudo bash install.sh repair
sudo bash install.sh uninstall
sudo bash install.sh status
sudo bash install.sh wizard
```

## What the installer does (step by step)

The installer runs 9 steps, with `clear` between each for a clean, friendly flow:

1. **Pre-flight checks** — verifies root, detects OS, exits if not Ubuntu LTS or Debian stable
2. **Installs system dependencies** — `apt-get install` of ca-certificates, curl, wget, git, jq, sqlite3, python3, docker, etc.
3. **Creates service user + directories** — `useradd --system zenvps` and `/opt/zenvps`, `/etc/zenvps`, `/var/lib/zenvps`, `/var/log/zenvps`, `/var/lib/zenvps/backups`
4. **Acquires source code** — `git clone` from `https://github.com/ZentrixDev/ZenVPS-Files.git` (or local copy if you chose that option) into `/opt/zenvps/`
5. **Installs Python runtime** — creates a venv at `/opt/zenvps/.venv`, installs `requirements.txt`
6. **Builds VPS Docker images** — `zenvps/ubuntu:22.04` and `zenvps/debian:12` from `docker/Dockerfile.*`
7. **Sets up configuration** — writes `/etc/zenvps/env` (mode `0600`, root-owned) from `.env.example`, then runs the wizard
8. **Installs systemd service** — `zenvps.service`, `zenvps-watchdog.{service,timer}`, `zenvps-anti-abuse.service`, logrotate, CLI tool
9. **Runs health checks** — verifies Docker, network, config file
10. **Starts the service** — `systemctl start zenvps`

If any step fails, the `trap ERR` handler runs the rollback log in reverse order, removing everything that was created.

## Post-install: the CLI tool

After install, `/usr/local/bin/zenvps` provides a wrapper:

```bash
zenvps start           # start the service
zenvps stop            # stop the service
zenvps restart         # restart the service
zenvps status          # show service status
zenvps logs -f         # follow logs (journalctl -f)
zenvps logs 100        # last 100 log lines
zenvps health          # run health checks
zenvps backup          # create a database backup
zenvps list-backups    # show available backups
zenvps restore <file>  # restore from a backup file
zenvps wizard          # re-run setup wizard
zenvps update          # update to the latest version
zenvps uninstall       # uninstall (preserves data + backups)
zenvps shell           # drop into a shell as the zenvps user (debug)
zenvps version         # show installed version
```

## File locations after install

| Path | Purpose |
|---|---|
| `/opt/zenvps/` | Source code + venv |
| `/etc/zenvps/env` | Configuration (mode `0600`, root-owned) |
| `/var/lib/zenvps/zenvps.json` | JSON database |
| `/var/lib/zenvps/backups/` | gzipped JSON snapshots |
| `/var/lib/zenvps/keys/` | Per-VPS SSH keypairs (host-SSH backend) |
| `/var/log/zenvps/` | Log files (daily rotation, 14-day retention) |
| `/etc/systemd/system/zenvps*.service` | systemd units |
| `/etc/logrotate.d/zenvps` | Log rotation |
| `/usr/local/bin/zenvps` | CLI tool |
| `/var/lib/zenvps/anti-abuse.sh` | Host-level miner killer |
| `/var/lib/zenvps/egress-filter.sh` | Network egress filter (opt-in) |

## Uninstall

```bash
sudo bash install.sh uninstall
```

This stops the service and removes:
- `/opt/zenvps/`
- All systemd units
- `/etc/logrotate.d/zenvps`
- `/usr/local/bin/zenvps`
- `zenvps/ubuntu:*` and `zenvps/debian:*` Docker images

It **preserves** (you must remove manually if you want them gone):
- `/var/lib/zenvps/` (database + keys + backups)
- `/etc/zenvps/` (config)
- `/var/log/zenvps/` (logs)
- The `zenvps` system user

## Troubleshooting

### "git clone failed"

The installer couldn't clone the bot source. Possible causes:
- The default repo URL (`https://github.com/ZentrixDev/ZenVPS-Files.git`) doesn't exist yet — you need to push the ZenVPS-Files source to that repo first
- No network access to github.com — check your firewall / DNS
- You're using a private fork — set `ZENVPS_REPO_URL` with embedded credentials or configure git SSH keys

**Fallback for offline install**: extract `ZenVPS-Files-v1.0.0.zip` next to the installer and re-run, then choose option 2 ("Use a local copy") when prompted. Or set `ZENVPS_SRC=/path/to/python` explicitly.

### "Unsupported OS"

You're not on Ubuntu LTS or Debian stable. The installer supports only:
- Ubuntu 20.04, 22.04, 24.04
- Debian 11, 12

### Docker not installed

The installer installs Docker via `get.docker.com`. If your network blocks that, install Docker manually first:

```bash
sudo apt-get install -y docker.io
sudo systemctl enable --now docker
```

Then re-run the installer.

### Service won't start

```bash
sudo journalctl -u zenvps -n 50 --no-pager
```

Common causes:
- `DISCORD_TOKEN` is empty → `sudo zenvps wizard` to set it
- `OWNER_IDS` is empty → same
- Docker daemon not running → `sudo systemctl start docker`

### Anti-abuse is killing legit processes

Edit `/var/lib/zenvps/anti-abuse.sh` and add your process name to the `WHITELIST_RE` regex, then:

```bash
sudo systemctl restart zenvps-anti-abuse.service
```

## Security notes

- The installer never writes the Discord token to source code. It goes straight to `/etc/zenvps/env` (mode `0600`).
- All `apt-get install` commands use `-y --no-install-recommends` to avoid pulling in unnecessary packages.
- The systemd unit includes hardening: `NoNewPrivileges`, `ProtectSystem=full`, `ProtectKernelTunables`, `CapabilityBoundingSet=` (empty).
- The `zenvps` system user has `/usr/sbin/nologin` as its shell — it can't be used for interactive logins.
- If you previously used any of the original VPS-bot projects, **revoke their Discord tokens immediately** at <https://discord.com/developers/applications> — they were committed in plaintext.

## License

MIT. See [`LICENSE`](LICENSE).

---

## Credits

**Made by [ZentrixDev](https://github.com/ZentrixDev)**

This project is a clean-room rewrite of several prior Discord VPS bot projects, addressing critical security vulnerabilities (leaked tokens, `--privileged` containers, hardcoded `root:root` SSH passwords, `pickle`-based backups, `shell=True` subprocess calls) and code-quality issues (65 bugs catalogued in `docs/BUGS_FIXED.md`). No code from the original projects is reproduced in this codebase — every file is original work.

If you find this project useful, please ⭐ star the repository on GitHub. Bug reports and pull requests are welcome.

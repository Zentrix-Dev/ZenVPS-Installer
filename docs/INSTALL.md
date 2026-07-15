# Installation guide

## Prerequisites

- A Linux VPS or dedicated host running **Ubuntu 20.04 / 22.04 / 24.04 LTS** or **Debian 11 / 12**
- Root access (the installer uses `sudo`)
- Internet access (the installer `git clone`s the bot source from GitHub)
- A Discord bot token from <https://discord.com/developers/applications>
- Your Discord user ID (enable Developer Mode in Discord → right-click yourself → Copy ID)
- At least 1 GB of free RAM and 10 GB of free disk

The installer refuses to run on any other OS (CentOS, Fedora, Alpine, Arch, etc.).

## Step 1: Get the installer

The installer is a single small ZIP. You don't need to download the bot source separately — the installer `git clone`s it for you.

```bash
# Download ZenVPS-Installer-v1.0.0.zip from the GitHub releases page, then:
unzip ZenVPS-Installer-v1.0.0.zip
cd ZenVPS-Installer
```

## Step 2: Run the installer

```bash
sudo bash install.sh install
```

The installer will:

1. Detect your OS and exit if it isn't Ubuntu LTS or Debian stable
2. Install system packages (curl, wget, git, jq, sqlite3, openssh-client, …)
3. Install Docker (if missing) via the official `get.docker.com` script
4. Create a `zenvps` system user
5. Create directories (`/opt/zenvps`, `/etc/zenvps`, `/var/lib/zenvps`, `/var/log/zenvps`)
6. **`git clone` the bot source from `https://github.com/ZentrixDev/ZenVPS-Files.git` into `/opt/zenvps`**
   - (or use a local copy if you choose that option / set `ZENVPS_SRC`)
7. Create a Python venv at `/opt/zenvps/.venv` and install `requirements.txt`
8. Build the Ubuntu 22.04 and Debian 12 VPS Docker images
9. Write a default config to `/etc/zenvps/env` (mode `0600`)
10. Install the systemd service, watchdog timer, anti-abuse service, logrotate config, and CLI tool
11. Run health checks
12. Start the service

If you're running in an interactive terminal, the **wizard** runs after step 9 to collect your bot token, owner ID, Discord server invite, and brand name. Otherwise edit `/etc/zenvps/env` manually.

### Choosing where the source comes from

When you run `install.sh install` interactively, you'll be asked:

```
Where should I get the ZenVPS source code from?

  1) Git clone from GitHub (default)
      Repo: https://github.com/ZentrixDev/ZenVPS-Files.git

  2) Use a local copy
      Looks for ZenVPS-Files/python/ next to this installer,
      or the path in $ZENVPS_SRC.

Choose [1/2] (default 1):
```

**Option 1 (git clone)** is recommended — it makes `install.sh update` work seamlessly later (just runs `git pull`).

**Option 2 (local copy)** is for offline installs or private forks. Extract `ZenVPS-Files-v1.0.0.zip` next to the installer first.

### Non-interactive install (CI / automation)

```bash
# Use defaults everywhere — git-clone from the default repo, no prompts
sudo bash install.sh install --yes

# Or override the repo URL
sudo ZENVPS_REPO_URL=https://github.com/your-fork/ZenVPS-Files.git \
     bash install.sh install --yes

# Or use a local source tree
sudo ZENVPS_SRC=/path/to/ZenVPS-Files/python bash install.sh install --yes
```

## Step 3: Configure

If you skipped the wizard, edit `/etc/zenvps/env` now:

```bash
sudo nano /etc/zenvps/env
```

The minimum required values:

```ini
DISCORD_TOKEN=<your bot token from the developer portal>
OWNER_IDS=<your Discord user ID>
```

Then restart the service:

```bash
sudo zenvps restart
```

## Step 4: Invite the bot to your server

1. Go to <https://discord.com/developers/applications>
2. Select your application → OAuth2 → URL Generator
3. Scopes: `bot`, `applications.commands`
4. Bot permissions: `Send Messages`, `Embed Links`, `Read Message History` (slash commands don't need message content intent)
5. Open the generated URL in your browser to invite the bot

## Step 5: Verify

```bash
sudo zenvps status
sudo zenvps logs -f
```

In Discord, type `/ping` — you should get a latency response.

## Installer commands

| Command | Description |
|---|---|
| `update` | Pull latest source, reinstall deps, rebuild Docker images, restart |
| `uninstall` | Stop service, remove files (preserves data + backups + config) |
| `repair` | Reinstall deps and re-sync service files (keeps your data) |
| `status` | Show service status, version, and config sanity |
| `wizard` | Re-run the interactive setup wizard |

## CLI tool

After install, `/usr/local/bin/zenvps` provides a wrapper:

```bash
zenvps start           # start the service
zenvps stop            # stop the service
zenvps restart         # restart the service
zenvps status          # show service status
zenvps logs -f         # follow logs
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

## File locations

| Path | Purpose |
|---|---|
| `/opt/zenvps/` | Source code (Python) |
| `/etc/zenvps/env` | Configuration (mode `0600`, root-owned) |
| `/var/lib/zenvps/zenvps.json` | Database (JSON + fcntl lock) |
| `/var/lib/zenvps/backups/` | gzipped JSON snapshots |
| `/var/lib/zenvps/keys/` | Per-VPS SSH keypairs (host-SSH backend) |
| `/var/log/zenvps/` | Log files (daily rotation, 14-day retention) |
| `/etc/systemd/system/zenvps.service` | Main systemd unit |
| `/etc/systemd/system/zenvps-watchdog.{service,timer}` | Watchdog |
| `/etc/systemd/system/zenvps-anti-abuse.service` | Host-level miner killer |
| `/etc/logrotate.d/zenvps` | Log rotation |
| `/usr/local/bin/zenvps` | CLI tool |

## Manual install (unsupported OS)

If you really need to run on a non-Ubuntu/Debian system, see the source of `installer/lib/helpers.sh` for the exact steps. You'll need to:

1. Create a `zenvps` user
2. Install Docker, git, Python 3.10+, and system packages manually
3. `git clone https://github.com/ZentrixDev/ZenVPS-Files.git /opt/zenvps` (or copy the source manually)
4. Create a venv at `/opt/zenvps/.venv` and install `/opt/zenvps/python/requirements.txt`
5. Write `/etc/zenvps/env` with `DISCORD_TOKEN` and `OWNER_IDS`
6. Install the systemd unit (adapt as needed for your init system)
7. Build the VPS Docker images from `docker/Dockerfile.ubuntu` and `docker/Dockerfile.debian`

No support is provided for non-Ubuntu/Debian installations.

## Troubleshooting

### Service won't start

```bash
sudo journalctl -u zenvps -n 50 --no-pager
```

Common causes:
- `DISCORD_TOKEN` is empty → edit `/etc/zenvps/env` and restart
- `OWNER_IDS` is empty → same
- Docker daemon not running → `sudo systemctl start docker`
- venv missing → `sudo bash installer/install.sh repair`

### Slash commands not appearing

Discord caches slash commands for up to 1 hour globally. To speed up testing, set `GUILD_ID` in `/etc/zenvps/env` to your test server's ID — guild-scoped commands sync instantly.

### Watchdog keeps restarting the bot

Check `journalctl -u zenvps` for the underlying error. The watchdog triggers after 3 consecutive 60-second health check failures. To disable temporarily:

```bash
sudo systemctl stop zenvps-watchdog.timer
```

### Anti-abuse is killing legit processes

Edit `/var/lib/zenvps/anti-abuse.sh` and add your process name to the `WHITELIST_RE` regex, then:

```bash
sudo systemctl restart zenvps-anti-abuse.service
```

### How to revoke the leaked token from the original project

If you uploaded the original `the original V3 archive.zip` anywhere, **revoke the Discord bot token immediately**:

1. Go to <https://discord.com/developers/applications>
2. Select the application
3. Bot → Reset Token
4. Update `/etc/zenvps/env` with the new token
5. `sudo zenvps restart`

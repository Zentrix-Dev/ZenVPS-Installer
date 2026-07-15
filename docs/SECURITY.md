# Security improvements

This document summarizes the security posture of the rebuild vs. the original V1/V4/the original V3 bots. A full bug-by-bug audit is in [`BUGS_FIXED.md`](BUGS_FIXED.md).

## Critical findings in the originals

### 1. Real Discord bot token committed to `the original V3 archive.zip`

The original `.env` file contained a working bot token. **That token must be revoked at <https://discord.com/developers/applications> immediately.**

The rebuild never stores tokens in source. Tokens live only in `/etc/zenvps/env` (mode `0600`, root-owned), and the `.env.example` file ships with `DISCORD_TOKEN=` empty.

### 2. `--privileged --cap-add=ALL` containers

Both V4 (`bot.py`) and the original V3 codebase (`the original bot file`) launched VPS containers with `--privileged --cap-add=ALL`. This gives the container:

- Full host device access (`/dev/sda`, `/dev/mem`, …)
- The ability to mount host filesystems
- Kernel module loading
- The ability to escape the container in seconds

The rebuild uses:

```
--cap-drop=ALL
--cap-add=CHOWN
--cap-add=SETUID
--cap-add=SETGID
--cap-add=NET_BIND_SERVICE
--security-opt=no-new-privileges:true
--pids-limit=512
--ulimit nofile=1024:1024
--ulimit nproc=256:256
--memory=<limit>m
--memory-swap=<limit>m   # disallow swap-to-disk
--cpus=<limit>
```

`--privileged` is never used. Users who need additional capabilities must explicitly add them via `EXTRA_CAPS`.

### 3. Hardcoded `root:root` password

The original Dockerfiles set `echo 'root:root' | chpasswd`. Anyone who found the source could SSH into every running VPS as root.

The rebuild:

- Sets `PermitRootLogin no` in sshd_config
- Locks the root password (`passwd -l root`) in the Dockerfile
- Generates a 24-char random root password per VPS at runtime, stored only in the encrypted database
- Creates a non-root user (random 7-char name) with a 20-char random password
- Sends credentials to the owner via DM with `||spoiler||` tags

### 4. `subprocess.run("docker rm -f $(sudo docker ps -a -q)", shell=True)`

The V4 bot used `shell=True` with user-supplied input in several places. While no exploit was actually reachable (the input was always the bot's own container IDs), the pattern is a textbook command-injection risk.

The rebuild:

- Never uses `shell=True`. All subprocess calls go through `asyncio.create_subprocess_exec` with a list of args.
- Every user-supplied string is validated by `zenvps.security` before reaching the subprocess layer.
- `safe_exec_args()` is a defense-in-depth check that rejects any arg containing shell metacharacters (`; & | \` $ ( ) { } [ ] < > \ \n \r`).

### 5. Token injected into source via `sed`

The V1 and V4 installers did:

```bash
sed -i "s/TOKEN = ''/TOKEN = '$DISCORD_TOKEN'/" main.py
```

This:

- Writes the token to disk in a source file
- Leaves it in shell history (`~/.bash_history`)
- Makes it visible to any process that can read `main.py`
- Survives uninstall (the source file stays on disk)

The rebuild:

- Tokens live in `/etc/zenvps/env` (mode `0600`, root-owned)
- The wizard writes the token directly to the env file, never to source
- Uninstall removes `/opt/zenvps` entirely; the env file is preserved only if the user explicitly confirms

### 6. Pickle for backups

The the original V3 bot used `pickle.dump()` / `pickle.load()` for backups. A malicious backup file can execute arbitrary code on restore.

The rebuild uses gzipped JSON. Restore is `json.loads()` — no code execution possible.

### 7. Hardcoded third-party API key

The V4 `bot.py` hardcoded `API_KEY = '<REDACTED — original archive contained a real a URL-shortening service API key>'` for a URL-shortening service. This key was visible to anyone who downloaded the source.

The rebuild has no third-party API keys and no ad/credit system. (The original "earn credits by shortening URLs" feature was an ad-revenue mechanism for the bot's author, not a user feature — it has been removed.)

### 8. Hardcoded owner ID

The the original V3 bot had `if ctx.author.id != <REDACTED — original owner's Discord user ID>:` for owner-only commands. Anyone reading the source knew exactly which user ID to spoof (in case of a future authentication bypass).

The rebuild reads `OWNER_IDS` from config. There is no hardcoded owner.

## Defense-in-depth layers

### Input validation

Every value that crosses a trust boundary passes through one of:

- `validate_docker_image()` — only images in `DEFAULT_OS_WHITELIST` allowed (or any image if `allow_custom=True`, which is never user-controlled)
- `validate_container_name()`, `validate_vps_id()`, `validate_username()` — strict regex
- `validate_port()`, `validate_memory_mb()`, `validate_cpu_cores()`, `validate_disk_mb()` — range checks
- `assert_no_path_traversal()` — rejects `..` and null bytes
- `sanitize_for_log()` — strips shell metacharacters before logging

### Secret scrubbing

The logger installs a `SecretScrubbingFilter` that scans every log message for:

- Discord tokens (50+ char alphanumeric)
- `password=`, `token=`, `secret=`, `key=` patterns
- SSH private key blocks (`-----BEGIN … PRIVATE KEY-----`)

Matches are replaced with `***REDACTED***` before being written to disk or the console.

### Permission system

Three roles with bit-flag permissions:

- **OWNER**: full power, can add/remove admins, reset database
- **ADMIN**: can manage any VPS, ban users, view admin stats
- **USER**: can only manage their own VPS

Banned users have no permissions at all (not even `USE_BOT`). The check is `PermissionChecker.can(user, Permission.CREATE_VPS)` — there is no path to a VPS operation that bypasses it.

### Container isolation

Beyond the `--cap-drop=ALL` / `--cap-add` hardening above:

- `--security-opt=no-new-privileges:true` — no `setuid` binaries can elevate
- `--pids-limit=512` — fork bombs die at 512 processes
- `--memory-swap` equals `--memory` — no swap-to-disk (prevents memory pressure on the host)
- `--ulimit nofile=1024:1024` — file-descriptor limit
- `--ulimit nproc=256:256` — per-user process limit
- `--tmpfs /tmp:rw,size=64m` — `/tmp` is a 64 MB tmpfs, not on disk
- `--read-only=false` but writes go to tmpfs (the rootfs is writable for apt-get, but `/tmp` and `/run` are tmpfs)

### Anti-abuse (4 layers)

1. **Container-level process scan** — every `MINER_CHECK_INTERVAL_SEC` seconds, the bot runs `ps aux` inside each VPS and matches against a curated miner-name regex with **word boundaries** (the original `anti.sh` used `index()` which matched substrings, so `pool` matched `swimmingpool`). Three strikes → suspend.

2. **cgroup CPU throttle** — every container gets `--cpus` from `CPU_THROTTLE_PERCENT`. A runaway VPS cannot starve its neighbours.

3. **Host-level `anti-abuse.sh`** — separate systemd service that scans host processes (not container processes) with `pgrep`. Catches container escapes. Whitelisted process names use exact-match regex.

4. **Network egress filter** — optional nftables/iptables rules blocking outbound to 50+ known mining-pool domains and stratum ports (3333, 4444, 5555, 7777, 9000, 14433, 14444, 3355).

### systemd hardening

The `zenvps.service` unit includes:

```ini
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/lib/zenvps /var/log/zenvps
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
CapabilityBoundingSet=
AmbientCapabilities=
MemoryMax=512M
CPUQuota=200%
```

The bot process has no capabilities, no access to `/home`, no access to most of `/usr`, and cannot load kernel modules.

### File permissions

| Path | Mode | Owner |
|---|---|---|
| `/etc/zenvps/env` | `0600` | `root:zenvps` |
| `/var/lib/zenvps/zenvps.json` | `0600` | `zenvps:zenvps` |
| `/var/lib/zenvps/zenvps.json.lock` | `0644` | `zenvps:zenvps` |
| `/var/lib/zenvps/keys/*` | `0600` | `zenvps:zenvps` |
| `/var/lib/zenvps/backups/*` | `0600` | `zenvps:zenvps` |
| `/opt/zenvps/` | `0750` | `zenvps:zenvps` |
| `/var/log/zenvps/` | `0750` | `zenvps:zenvps` |

### No `pickle`, no `eval`, no `exec`

- Backups use `json.loads()` (not `pickle.load()`)
- The Dockerfile template uses `str.replace()` (not `str.format()`) to avoid format-string injection
- No `os.system()`, no `subprocess.run(shell=True)`, no `eval()`, no `exec()` anywhere in the codebase

### Rate limiting & reconnect

- discord.py's built-in rate-limit handler is used (no manual ratelimit code)
- `auto_reconnect=True` handles WebSocket drops
- The watchdog restarts the bot after 3 consecutive 60-second health check failures
- systemd's `Restart=on-failure` with `RestartSec=5s` covers process crashes

## What was NOT changed (intentional)

- **`--privileged` is still available** via `DROP_ALL_CAPS=false` + `EXTRA_CAPS=ALL`. This is documented as dangerous but not removed, because some legitimate workloads (Docker-in-Docker, systemd with cgroup v2 delegation) require it. The default is safe.
- **serveo.net is still supported** as a remote-access backend. It is a third-party service and could log traffic. Disable with `ENABLE_SERVEO=false`.
- **sshx.io is still supported**. Same caveat. Disable with `ENABLE_SSHX=false`.

## Reporting a vulnerability

Email security@your-org.example with details. We will acknowledge within 48 hours and aim to ship a fix within 7 days for critical issues.

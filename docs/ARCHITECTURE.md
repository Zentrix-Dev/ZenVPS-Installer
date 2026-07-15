# Architecture

This document walks through the structure of the rebuild, the reasoning behind the major design decisions, and how data flows through the system.

## High-level diagram

```
┌────────────────────────────────────────────────────────────┐
│                       Discord (WebSocket)                  │
└──────────────────────────────┬─────────────────────────────┘
                               │ slash commands
┌──────────────────────────────┴─────────────────────────────┐
│                     VPSBot (commands.Bot)                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ UserCmds │  │AdminCmds │  │RemoteCmds│  │ MetaCmds │   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘   │
│       │              │              │              │         │
│  ┌────┴──────────────┴──────────────┴──────────────┴────┐  │
│  │              PermissionChecker (RBAC)                │  │
│  └──────────────────────┬───────────────────────────────┘  │
└─────────────────────────┼──────────────────────────────────┘
                          │
        ┌─────────────────┼─────────────────────┐
        │                 │                     │
   ┌────┴─────┐    ┌──────┴──────┐      ┌──────┴──────┐
   │Database  │    │DockerManager│      │   Remote    │
   │(JSON+    │    │  (CLI via   │      │  backends   │
   │ flock)   │    │  async sub) │      │ ┌─────────┐ │
   └──────────┘    └──────┬──────┘      │ │ tmate   │ │
                          │             │ │ sshx    │ │
                          │             │ │ serveo  │ │
                          │             │ │ host_ssh│ │
                          │             │ └─────────┘ │
                          │             └─────────────┘
                          │
                   ┌──────┴──────┐
                   │  Docker     │
                   │  daemon     │
                   │  (/var/run/ │
                   │  docker.sock)│
                   └──────┬──────┘
                          │
                   ┌──────┴──────┐
                   │  VPS        │
                   │  containers │
                   │  (ubuntu,   │
                   │   debian)   │
                   └─────────────┘
```

## Module responsibilities

### `config.py`

Loads, validates, and exposes all runtime configuration. Every value is checked on startup; invalid values raise `ConfigError` with a human-friendly message. No silent defaults for invalid input.

The `Config` dataclass is the single source of truth. Subsystems receive it as a constructor argument — no module reaches into global state for configuration.

### `database.py`

JSON-on-disk with `fcntl.flock`. The schema is a single document:

```json
{
  "schema_version": 1,
  "vps": { "<vps_id>": { ... } },
  "users": { "<user_id>": { ... } },
  "admins": ["<user_id>", ...],
  "settings": { ... },
  "stats": { ... }
}
```

Every public method acquires the lock for the duration of the read+write. Writes are atomic via `tmp + os.replace`.

### `docker_mgr.py`

Wraps the `docker` CLI. Every `docker run` for a VPS goes through `DockerManager.run_vps`, which enforces the security profile (`--cap-drop=ALL`, `--memory`, `--cpus`, `--pids-limit`, `--security-opt=no-new-privileges`).

Why the CLI and not the `docker` Python SDK?

1. The SDK is synchronous. Wrapping every call in `asyncio.to_thread` obscures error handling.
2. The SDK has no native timeout support.
3. The SDK's object lifecycle (`Container.reload()`, lazy attributes) interacts poorly with async.
4. The CLI is easier to audit (no opaque method calls).

### `security.py`

Pure-function validators. No I/O, no side effects. Every function either returns the validated value or raises `ValidationError` with a message safe to show to users.

Also contains the secret generators: `generate_vps_id()`, `generate_token()`, `generate_password()`, `generate_username()`. All use `secrets.SystemRandom` (cryptographically secure).

### `permissions.py`

`PermissionChecker` is constructed once at startup with the owner/admin/admin-role/banned ID sets. Checks are O(1) set lookups.

Permissions are bit flags (`Permission.CREATE_VPS = 1 << 1`, etc.) so checks compose: `can(user, Permission.MANAGE_ANY_VPS | Permission.BAN_USERS)`.

### `remote/`

Four pluggable backends with the same interface:

```python
class Backend:
    @staticmethod
    async def create(container_id, vps, cfg) -> dict: ...
    @staticmethod
    async def revoke(container_id, vps, cfg) -> None: ...
    @staticmethod
    async def status(container_id, vps, cfg) -> str: ...
```

Adding a new backend (e.g. ngrok) is a matter of implementing those three methods and adding an `enable_<name>` flag to `Config`.

### `anti_abuse.py`

Background `asyncio.Task` that wakes every `MINER_CHECK_INTERVAL_SEC` seconds, iterates every running VPS, runs `ps aux` inside the container, and matches the output against curated regex patterns. Three strikes → suspend.

Patterns use `\b` word boundaries to avoid the original `anti.sh` bug where `pool` matched `swimmingpool`.

### `watchdog.py`

Background task that probes Discord latency and Docker reachability every `WATCHDOG_INTERVAL_SEC` seconds. After `WATCHDOG_FAILURE_THRESHOLD` consecutive failures, it writes a marker file and calls `os._exit(2)`. systemd's `Restart=on-failure` brings the bot back.

The external `zenvps-watchdog.timer` (60s cron-like) is a belt-and-suspenders layer: if the bot's own watchdog task is hung, the systemd timer notices and restarts the service.

### `backup.py`

`backup()` writes a gzipped JSON snapshot with atomic rename. Old backups are pruned to `LOG_KEEP_DAYS`.

`restore()` uses `json.loads()` — never `pickle`. A tampered backup file can at worst cause a `JSONDecodeError`, never code execution.

### `logger.py`

`setup_logging()` configures:

- Console handler with ANSI colors (when stderr is a TTY)
- Daily-rotating file handler for `zenvps.log`
- Daily-rotating error-only handler for `zenvps-error.log`
- Separate audit logger (writes only to `zenvps-audit.log`)
- Separate security logger (writes only to `zenvps-security.log`)

The `SecretScrubbingFilter` scans every message and arg for Discord tokens, `password=…` patterns, and SSH private key blocks. Matches are replaced with `***REDACTED***` before formatting.

### `cogs/`

Four cog/command modules:

- `user_cmds` — `/deploy`, `/list`, `/vps …` (user VPS management)
- `admin_cmds` — `/admin …` (admin/owner operations)
- `remote_cmds` — `/ssh …` (remote-access backends)
- `meta_cmds` — `/ping`, `/help`, `/health`, `/version`, `/about`

Each command:

1. Validates input via `security.py`
2. Checks permissions via `permissions.py`
3. Performs the operation via `docker_mgr.py` / `database.py` / `remote/*`
4. Returns a standardized embed from `ui/embeds.py`

### `ui/`

- `embeds.py` — builders for `success_embed`, `error_embed`, `vps_embed`, etc. All embeds include the brand name in the footer.
- `views.py` — persistent button views for VPS management (Start/Stop/Restart/Regen/Delete).
- `modals.py` — modal dialogs (transfer VPS, ban user with reason).

## Data flow: `/deploy` walkthrough

1. User types `/deploy os_image=ubuntu:22.04 memory_mb=2048` in Discord
2. Discord sends an interaction payload to the bot's WebSocket
3. `discord.py` dispatches to `UserCommands.deploy` callback
4. The callback:
   - Checks `permissions.is_banned(user_id)` → returns early if banned
   - Validates `os_image`, `memory_mb` via `security.validate_*`
   - Checks `db.count_user_vps(user_id) < cfg.max_vps_per_user`
   - Checks `db.count_total_vps() < cfg.max_total_vps`
   - Calls `interaction.response.send_message` to acknowledge (Discord requires a response within 3s)
   - Calls `docker.run_vps(...)` which:
     - Validates inputs again (defense in depth)
     - Pings Docker
     - Pulls the image if missing
     - Generates a random username + 20-char password + 24-char root password
     - Builds the `docker run` arg list with all hardening flags
     - Calls `asyncio.create_subprocess_exec("docker", "run", ...)`
     - Captures the container ID
     - Runs `docker exec … bash -c '<setup script>'` to create the user, lock root, configure SSH
   - Calls `db.upsert_vps(vps_dict)` to persist the new VPS
   - Provisions remote backends concurrently via `asyncio.gather`
   - Updates the VPS record with the captured `tmate_session` / `sshx_session` / `host_ssh_command`
   - DMs the user with an embed containing the credentials (spoiler-tagged)
   - Sends a public follow-up confirming success

Total time: 8–15 seconds typical, 30 seconds worst case (image pull).

## Data flow: anti-abuse scan

1. `AntiAbuseMonitor._loop` wakes every 300s (configurable)
2. For each VPS with `status == 'running'`:
   - `docker.status(container_id)` — quick `docker inspect`
   - If not running, skip
   - `docker exec <cid> ps aux` — capture up to 256 KB
   - Lowercase the output
   - For each pattern in `MINER_PATTERNS` + `ABUSE_PATTERNS`:
     - `pattern.search(output)` — word-boundary regex
     - On match, record the matched string
   - If no matches, decay `miner_strikes` by 1 (down to 0)
   - If matches:
     - `db.increment_miner_strike(vps_id)` → returns new strike count
     - Log to security logger
     - DM the owner with the strike count
     - If strikes >= `cfg.miner_strike_limit`:
       - `docker.stop(container_id)`
       - `db.update_vps(vps_id, {status: 'suspended', miner_strikes: 0})`
       - DM the owner with the suspension notice
3. Sleep `MINER_CHECK_INTERVAL_SEC` and repeat

## Reliability model

```
                          ┌──────────────────────────┐
                          │ systemd                  │
                          │  Restart=on-failure      │
                          │  RestartSec=5s           │
                          └──────────┬───────────────┘
                                     │
                          ┌──────────┴───────────────┐
                          │ zenvps.service          │
                          │  (the Python bot)        │
                          └──────────┬───────────────┘
                                     │
                  ┌──────────────────┼──────────────────┐
                  │                  │                  │
        ┌─────────┴────────┐ ┌───────┴────────┐ ┌───────┴────────┐
        │ In-process       │ │ External       │ │ External       │
        │ watchdog task    │ │ systemd timer  │ │ anti-abuse.svc │
        │ (60s loop)       │ │ (60s cron)     │ │ (5s loop)      │
        └──────────────────┘ └────────────────┘ └────────────────┘
```

- The in-process watchdog handles bot-side hangs (Discord latency spike, deadlocks)
- The external systemd timer handles process-level hangs (the in-process watchdog can't fire if the entire process is frozen)
- The anti-abuse service runs independently — even if the bot crashes, miners are still killed

## Why Python?

Python was chosen for several reasons:

- **Mature ecosystem** — `discord.py` 2.x is the most battle-tested Discord library, with first-class support for slash commands, async, and rate-limit handling.
- **Readable code** — Python's syntax is approachable for contributors of all skill levels, which matters for an open-source project.
- **Rich standard library** — `asyncio`, `json`, `fcntl`, `subprocess`, `secrets`, `re`, `pathlib` cover everything we need without external dependencies.
- **Easy deployment** — a single venv with `pip install -r requirements.txt` is all that's needed; no compilation step.
- **Easy debugging** — `python -m zenvps` runs directly from source, no build step required.

The codebase is structured so that porting to another language would be straightforward — the modules have clear interfaces and the database schema is plain JSON.


## Extension points

### Adding a new remote-access backend

1. Create `python/src/zenvps/remote/<name>.py` with `create`, `revoke`, `status` methods
2. Add `enable_<name>: bool = False` to `Config` and `ENABLE_<NAME>=false` to `.env.example`
3. Expose it on the bot: `self.remote_<name> = <Name>Backend`
4. Wire it into `/deploy` and `/vps delete` in `cogs/user_cmds.py`
5. Add a `/ssh <name> <vps_id>` subcommand in `cogs/remote_cmds.py`

### Adding a new slash command

1. Add the command to the appropriate cog (`user_cmds`, `admin_cmds`, etc.)
2. Use the `permission` decorators / `permissions.is_admin(interaction)` checks
3. Use `ui/embeds.py` builders for the response
4. If the command takes user input, validate it via `security.py`

### Adding a new Docker image

1. Add `Dockerfile.<os>` to `docker/`
2. Add the image name to `DEFAULT_OS_WHITELIST` in `security.py`
3. Add a build step to `installer/lib/docker.sh`

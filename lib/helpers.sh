# shellcheck shell=bash
# Helper functions sourced by install.sh.
# Split into sections for readability, but kept in one file so the installer
# has only one dependency.

# ---------------------------------------------------------------------------
# Section 1: System dependencies
# ---------------------------------------------------------------------------

install_system_deps() {
  info "Updating package lists"
  apt-get update -qq

  info "Installing base packages"
  local pkgs=(
    ca-certificates curl wget gnupg lsb-release apt-transport-https
    software-properties-common openssh-client ufw logrotate rsyslog
    jq sqlite3 git
    python3 python3-pip python3-venv python3-dev
  )
  apt-get install -y -qq "${pkgs[@]}"

  # Detect and repair missing packages
  local missing=()
  for pkg in "${pkgs[@]}"; do
    if ! dpkg -l "${pkg}" &>/dev/null; then
      missing+=("${pkg}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Reinstalling missing packages: ${missing[*]}"
    apt-get install -y --reinstall "${missing[@]}"
  fi

  # Repair broken installations
  info "Repairing broken installations (if any)"
  apt-get -f install -y -qq || true

  # Docker
  if ! command -v docker &>/dev/null; then
    info "Docker not found — installing via official script"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    systemctl enable --now docker
    rollback_record "systemctl disable --now docker 2>/dev/null || true"
  else
    info "Docker already installed: $(docker --version)"
  fi

  if ! systemctl is-active --quiet docker; then
    info "Starting Docker service"
    systemctl enable --now docker
  fi

  # Add the zenvps user to the docker group
  if ! id -nG "${RUN_USER}" 2>/dev/null | grep -qw docker; then
    info "Adding ${RUN_USER} to docker group"
    usermod -aG docker "${RUN_USER}"
  fi

  install_log "System dependencies installed"
}

# ---------------------------------------------------------------------------
# Section 2: Python runtime
# ---------------------------------------------------------------------------

install_python_runtime() {
  info "Setting up Python virtualenv"
  local venv="${INSTALL_DIR}/.venv"
  if [[ ! -d "${venv}" ]]; then
    sudo -u "${RUN_USER}" python3 -m venv "${venv}"
  fi

  info "Installing Python dependencies"
  sudo -u "${RUN_USER}" "${venv}/bin/pip" install --quiet --upgrade pip
  if [[ -f "${INSTALL_DIR}/requirements.txt" ]]; then
    sudo -u "${RUN_USER}" "${venv}/bin/pip" install --quiet -r "${INSTALL_DIR}/requirements.txt"
  fi

  # Write a wrapper script that the systemd unit will call
  cat > "${INSTALL_DIR}/run.sh" <<EOF
#!/bin/bash
exec "${venv}/bin/python" -m zenvps "\$@"
EOF
  chmod 0755 "${INSTALL_DIR}/run.sh"
  chown "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}/run.sh"

  install_log "Python runtime ready"
}

# ---------------------------------------------------------------------------
# Section 3: Acquire / update source code
#
# Two modes:
#   - acquire_source:  fresh install — git clone from REPO_URL (or use local)
#   - update_source:   existing install — git pull (or re-copy local)
#
# The default repo URL is https://github.com/ZentrixDev/ZenVPS-Files.git
# Override with the ZENVPS_REPO_URL env var.
#
# If you'd rather not git-clone (e.g. offline install), extract the
# ZenVPS-Files-v1.0.0.zip next to the installer and the functions below
# will detect the local copy automatically.
# ---------------------------------------------------------------------------

# Detect a local ZenVPS source tree (used as fallback when git is unavailable
# or when ZENVPS_SRC / a sibling ZenVPS-Files/ directory exists).
_resolve_local_source() {
  local candidates=(
    "${ZENVPS_SRC:-}"
    "${SCRIPT_DIR}/../python"
    "${SCRIPT_DIR}/../ZenVPS-Files/python"
    "${SCRIPT_DIR}/python"
  )
  for c in "${candidates[@]}"; do
    [[ -z "${c}" ]] && continue
    if [[ -d "${c}" ]] && [[ -f "${c}/requirements.txt" ]]; then
      echo "${c}"
      return 0
    fi
  done
  return 1
}

# Fresh-install path.  Asks the user (or uses defaults under --yes) whether
# to git-clone or use a local copy, then populates ${INSTALL_DIR}.
acquire_source() {
  # Decide where to get the source from
  local mode=""  # "git" or "local"

  # If ZENVPS_SRC is set explicitly, always use local
  if [[ -n "${ZENVPS_SRC:-}" ]] && [[ -d "${ZENVPS_SRC}" ]]; then
    mode="local"
  elif [[ "${ASSUME_YES}" != "1" ]] && [[ -t 0 ]]; then
    # Interactive: ask the user
    echo "  Where should I get the ZenVPS source code from?"
    echo
    echo "  ${B}1${R}) Git clone from GitHub (default)"
    echo "      Repo: ${CYN}${REPO_URL}${R}"
    echo
    echo "  ${B}2${R}) Use a local copy"
    echo "      Looks for ZenVPS-Files/python/ next to this installer,"
    echo "      or the path in \$ZENVPS_SRC."
    echo
    read -p "$(ask 'Choose [1/2] (default 1): ')" choice
    case "${choice}" in
      2) mode="local" ;;
      *) mode="git" ;;
    esac
  else
    # Non-interactive: default to git clone
    mode="git"
  fi

  if [[ "${mode}" == "git" ]]; then
    _clone_from_git
  else
    _copy_from_local
  fi

  chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}"
  chmod -R go-w "${INSTALL_DIR}"
}

# Update path.  If ${INSTALL_DIR} is a git checkout, pull.  Otherwise re-copy
# from local.  Used by `install.sh update` and `install.sh repair`.
update_source() {
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "Git checkout detected — pulling latest changes"
    sudo -u "${RUN_USER}" git -C "${INSTALL_DIR}" fetch --quiet origin
    sudo -u "${RUN_USER}" git -C "${INSTALL_DIR}" reset --hard origin/HEAD
    sudo -u "${RUN_USER}" git -C "${INSTALL_DIR}" clean -fdq
    install_log "Source updated via git pull"
  else
    info "Not a git checkout — re-copying from local source"
    _copy_from_local
  fi
  chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}"
  chmod -R go-w "${INSTALL_DIR}"
}

# Clone from ${REPO_URL} into ${INSTALL_DIR}.
_clone_from_git() {
  if ! command -v git &>/dev/null; then
    err "git is not installed. Install it with: sudo apt-get install -y git"
    exit 1
  fi

  info "Cloning ZenVPS source from:"
  echo "  ${CYN}${REPO_URL}${R}"
  echo

  # Wipe install dir contents (but keep the dir itself)
  rm -rf "${INSTALL_DIR:?}/"*

  # Clone — depth 1 keeps it small (full history can be fetched later if needed)
  if ! sudo -u "${RUN_USER}" git clone --depth 1 "${REPO_URL}" "${INSTALL_DIR}"; then
    err "git clone failed."
    err ""
    err "Possible causes:"
    err "  • The repo URL is wrong (check ZENVPS_REPO_URL)"
    err "  • You have no network access to github.com"
    err "  • The repo is private and you need to configure git credentials"
    err ""
    err "Fallback: extract ZenVPS-Files-v1.0.0.zip next to this installer"
    err "and re-run, then choose option 2 (local copy) when prompted."
    exit 1
  fi

  # The repo may have a python/ subdirectory (ZenVPS-Files layout) — if so,
  # move its contents up one level so ${INSTALL_DIR}/requirements.txt exists.
  if [[ -d "${INSTALL_DIR}/python" ]] && [[ ! -f "${INSTALL_DIR}/requirements.txt" ]]; then
    info "Detected python/ subdirectory — flattening"
    # Move python/* up one level (keep .git at the top so updates still work)
    (cd "${INSTALL_DIR}/python" && cp -a . "${INSTALL_DIR}/")
    rm -rf "${INSTALL_DIR}/python"
  fi

  # Remove build artifacts that may have come along, but KEEP .git so that
  # `install.sh update` can pull changes later.
  rm -rf "${INSTALL_DIR}/__pycache__" "${INSTALL_DIR}/.venv" "${INSTALL_DIR}/.pytest_cache"

  # Save the repo URL so `update_source` knows where to pull from
  echo "${REPO_URL}" > "${INSTALL_DIR}/.source-repo"
  chmod 0640 "${INSTALL_DIR}/.source-repo"

  install_log "Source cloned from ${REPO_URL}"
}

# Copy from a local ZenVPS-Files/python/ directory.
_copy_from_local() {
  local src_dir
  if ! src_dir="$(_resolve_local_source)"; then
    err "Could not find the ZenVPS Python source code locally."
    err "Looked in:"
    err "  • \$ZENVPS_SRC (env var)"
    err "  • ${SCRIPT_DIR}/../python"
    err "  • ${SCRIPT_DIR}/../ZenVPS-Files/python"
    err "  • ${SCRIPT_DIR}/python"
    err ""
    err "Either:"
    err "  1. Extract ZenVPS-Files-v1.0.0.zip next to this installer, or"
    err "  2. Set ZENVPS_SRC=/path/to/python, or"
    err "  3. Re-run and choose option 1 (git clone) when prompted."
    exit 1
  fi
  info "Using local source: ${src_dir}"

  info "Copying to ${INSTALL_DIR}"
  rm -rf "${INSTALL_DIR:?}/"*
  cp -a "${src_dir}/." "${INSTALL_DIR}/"
  rm -rf "${INSTALL_DIR}/__pycache__" "${INSTALL_DIR}/.venv" "${INSTALL_DIR}/.pytest_cache"

  install_log "Source copied from ${src_dir}"
}

# ---------------------------------------------------------------------------
# Section 4: Build VPS Docker images
# ---------------------------------------------------------------------------

build_vps_images() {
  local docker_dir=""
  for c in "${SCRIPT_DIR}/docker" "${SCRIPT_DIR}/../docker"; do
    if [[ -d "${c}" ]]; then docker_dir="${c}"; break; fi
  done
  if [[ -z "${docker_dir}" ]]; then
    warn "docker/ directory not found — skipping VPS image builds"
    return
  fi

  info "Building Ubuntu 22.04 VPS image"
  if [[ -f "${docker_dir}/Dockerfile.ubuntu" ]]; then
    docker build -q -t zenvps/ubuntu:22.04 -f "${docker_dir}/Dockerfile.ubuntu" "${docker_dir}" \
      || warn "Ubuntu image build failed — /deploy will fall back to pulling ubuntu:22.04"
  fi

  info "Building Debian 12 VPS image"
  if [[ -f "${docker_dir}/Dockerfile.debian" ]]; then
    docker build -q -t zenvps/debian:12 -f "${docker_dir}/Dockerfile.debian" "${docker_dir}" \
      || warn "Debian image build failed — /deploy will fall back to pulling debian:12"
  fi

  install_log "Docker images built"
}

# ---------------------------------------------------------------------------
# Section 5: Install systemd service, logrotate, CLI tool
# ---------------------------------------------------------------------------

install_service() {
  local systemd_dir=""
  for c in "${SCRIPT_DIR}/systemd" "${SCRIPT_DIR}/../systemd"; do
    if [[ -d "${c}" ]]; then systemd_dir="${c}"; break; fi
  done
  if [[ -z "${systemd_dir}" ]]; then
    err "systemd/ directory not found"
    exit 1
  fi

  info "Installing systemd unit: ${SERVICE_NAME}.service"
  install -m 0644 "${systemd_dir}/${SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_NAME}.service"
  rollback_record "rm -f /etc/systemd/system/${SERVICE_NAME}.service"

  info "Installing watchdog unit + timer"
  [[ -f "${systemd_dir}/${SERVICE_NAME}-watchdog.service" ]] && {
    install -m 0644 "${systemd_dir}/${SERVICE_NAME}-watchdog.service" "/etc/systemd/system/${SERVICE_NAME}-watchdog.service"
    rollback_record "rm -f /etc/systemd/system/${SERVICE_NAME}-watchdog.service"
  }
  [[ -f "${systemd_dir}/${SERVICE_NAME}-watchdog.timer" ]] && {
    install -m 0644 "${systemd_dir}/${SERVICE_NAME}-watchdog.timer" "/etc/systemd/system/${SERVICE_NAME}-watchdog.timer"
    rollback_record "rm -f /etc/systemd/system/${SERVICE_NAME}-watchdog.timer"
  }

  info "Installing anti-abuse service"
  [[ -f "${systemd_dir}/${SERVICE_NAME}-anti-abuse.service" ]] && {
    install -m 0644 "${systemd_dir}/${SERVICE_NAME}-anti-abuse.service" "/etc/systemd/system/${SERVICE_NAME}-anti-abuse.service"
    rollback_record "rm -f /etc/systemd/system/${SERVICE_NAME}-anti-abuse.service"
  }

  # logrotate
  local logrotate_dir=""
  for c in "${SCRIPT_DIR}/logrotate" "${SCRIPT_DIR}/../logrotate"; do
    if [[ -d "${c}" ]]; then logrotate_dir="${c}"; break; fi
  done
  if [[ -n "${logrotate_dir}" && -f "${logrotate_dir}/zenvps" ]]; then
    info "Installing logrotate config"
    install -m 0644 "${logrotate_dir}/zenvps" /etc/logrotate.d/zenvps
    rollback_record "rm -f /etc/logrotate.d/zenvps"
  fi

  # CLI tool + helper scripts
  local scripts_dir=""
  for c in "${SCRIPT_DIR}/scripts" "${SCRIPT_DIR}/../scripts"; do
    if [[ -d "${c}" ]]; then scripts_dir="${c}"; break; fi
  done
  if [[ -n "${scripts_dir}" ]]; then
    info "Installing CLI wrapper at /usr/local/bin/zenvps"
    [[ -f "${scripts_dir}/zenvps" ]] && {
      install -m 0755 "${scripts_dir}/zenvps" /usr/local/bin/zenvps
      rollback_record "rm -f /usr/local/bin/zenvps"
    }

    info "Installing anti-abuse script"
    [[ -f "${scripts_dir}/anti-abuse.sh" ]] && {
      install -m 0755 "${scripts_dir}/anti-abuse.sh" "${DATA_DIR}/anti-abuse.sh"
      chown root:root "${DATA_DIR}/anti-abuse.sh"
    }

    info "Installing egress filter script"
    [[ -f "${scripts_dir}/egress-filter.sh" ]] && {
      install -m 0755 "${scripts_dir}/egress-filter.sh" "${DATA_DIR}/egress-filter.sh"
      chown root:root "${DATA_DIR}/egress-filter.sh"
    }
  fi

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" 2>/dev/null
  systemctl enable "${SERVICE_NAME}-watchdog.timer" 2>/dev/null
  systemctl enable "${SERVICE_NAME}-anti-abuse.service" 2>/dev/null
  systemctl start "${SERVICE_NAME}-watchdog.timer" 2>/dev/null || true
  systemctl start "${SERVICE_NAME}-anti-abuse.service" 2>/dev/null || true

  install_log "Service files installed"
}

# ---------------------------------------------------------------------------
# Section 6: Health checks
# ---------------------------------------------------------------------------

run_health_checks() {
  info "Verifying dependencies"
  for cmd in docker curl jq python3; do
    if ! command -v "${cmd}" &>/dev/null; then
      err "Missing required command: ${cmd}"
      exit 1
    fi
  done
  if [[ ! -x "${INSTALL_DIR}/.venv/bin/python" ]]; then
    err "Python venv not found at ${INSTALL_DIR}/.venv"
    exit 1
  fi
  ok "All dependencies present"

  info "Verifying Docker daemon"
  if ! docker info &>/dev/null; then
    err "Docker daemon is not running. Start it with: sudo systemctl start docker"
    exit 1
  fi
  ok "Docker daemon is reachable"

  info "Verifying network connectivity"
  if ! curl -sf --max-time 5 https://discord.com -o /dev/null; then
    warn "Cannot reach https://discord.com — bot may fail to connect"
  else
    ok "Network OK (discord.com reachable)"
  fi

  info "Verifying configuration"
  if [[ ! -f "${CONFIG_DIR}/env" ]]; then
    warn "Config file not present at ${CONFIG_DIR}/env"
  else
    if grep -q "^DISCORD_TOKEN=$" "${CONFIG_DIR}/env"; then
      warn "DISCORD_TOKEN is empty in ${CONFIG_DIR}/env"
      warn "Edit the file and paste your bot token from https://discord.com/developers/applications"
    else
      ok "DISCORD_TOKEN is set"
    fi
    if grep -q "^OWNER_IDS=$" "${CONFIG_DIR}/env"; then
      warn "OWNER_IDS is empty — the bot will refuse to start without at least one owner ID"
    fi
  fi

  info "Verifying directory permissions"
  for d in "${DATA_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"; do
    if [[ ! -w "${d}" ]]; then
      err "Directory not writable: ${d}"
      exit 1
    fi
  done
  ok "Directory permissions OK"

  install_log "Health checks passed"
}

# ---------------------------------------------------------------------------
# Section 7: Rollback
# ---------------------------------------------------------------------------

rollback_record() {
  local cmd="$1"
  if [[ -n "${ROLLBACK_LOG:-}" ]]; then
    echo "${cmd}" >> "${ROLLBACK_LOG}"
  fi
}

rollback_apply() {
  local log_file="$1"
  [[ -f "${log_file}" ]] || return 0
  info "Applying rollback (running commands in reverse order)"
  while IFS= read -r cmd; do
    eval "${cmd}" 2>/dev/null || true
  done < <(tac "${log_file}")
  info "Rollback complete"
}

# ---------------------------------------------------------------------------
# Section 8: Interactive setup wizard
# ---------------------------------------------------------------------------

wizard_run() {
  local env_file="$1"
  [[ -f "${env_file}" ]] || { err "env file not found: ${env_file}"; return 1; }

  clear
  echo -e "${B}${MAG}╔══════════════════════════════════════════╗${R}"
  echo -e "${B}${MAG}║          ZenVPS Setup Wizard             ║${R}"
  echo -e "${B}${MAG}╚══════════════════════════════════════════╝${R}"
  echo
  echo "This wizard will collect the information ZenVPS needs to run."
  echo "All values are stored in: ${CYN}${env_file}${R}"
  echo "Press ${B}Ctrl+C${R} at any time to cancel (no changes will be saved)."
  echo
  echo -e "${GRY}────────────────────────────────────────────────────────${R}"
  echo

  # ------------------------------------------------------------------
  # 1. Discord bot token (REQUIRED)
  # ------------------------------------------------------------------
  echo -e "${B}Step 1 of 6 — Discord bot token${R} ${RED}(required)${R}"
  echo "  Get this from: ${CYN}https://discord.com/developers/applications${R}"
  echo "  → Select your application → Bot → Token → Copy"
  echo "  The token is 50+ characters, looks like:"
  echo "    MTIzNDU2Nzg5MDEyMzQ1Njc4.GaBcDe.XyZ_abc123-def456-ghi789"
  echo
  local token=""
  while [[ -z "${token}" ]]; do
    read -p "$(ask 'Paste your bot token: ')" token
    if [[ -z "${token}" ]]; then
      warn "Bot token is required. The bot cannot run without it."
    elif [[ ! "${token}" =~ ^[A-Za-z0-9_.\-]{50,}$ ]]; then
      warn "That doesn't look like a bot token (should be 50+ chars). Try again."
      token=""
    fi
  done
  echo

  # ------------------------------------------------------------------
  # 2. Owner Discord user ID (REQUIRED)
  # ------------------------------------------------------------------
  echo -e "${B}Step 2 of 6 — Your Discord user ID${R} ${RED}(required)${R}"
  echo "  This user will have full owner privileges (can add/remove admins, reset DB)."
  echo "  To find your user ID:"
  echo "    1. Discord Settings → Advanced → Enable ${B}Developer Mode${R}"
  echo "    2. Right-click your username → ${B}Copy ID${R}"
  echo "  The ID is a 17-20 digit number, e.g. 100000000000000001"
  echo
  local owner_ids=""
  while [[ -z "${owner_ids}" ]]; do
    read -p "$(ask 'Enter your Discord user ID: ')" owner_ids
    if [[ -z "${owner_ids}" ]]; then
      warn "Owner ID is required. The bot refuses to start without at least one owner."
    elif [[ ! "${owner_ids}" =~ ^[0-9]{17,20}(,[0-9]{17,20})*$ ]]; then
      warn "User IDs are 17-20 digit numbers (comma-separated for multiple). Try again."
      owner_ids=""
    fi
  done
  echo

  # ------------------------------------------------------------------
  # 3. Discord server (guild) ID (RECOMMENDED)
  # ------------------------------------------------------------------
  echo -e "${B}Step 3 of 6 — Discord server (guild) ID${R} ${YLW}(recommended)${R}"
  echo "  This is the Discord server where the bot will operate."
  echo "  Entering it makes slash-command sync instant (1-2s)."
  echo "  Leave blank to sync globally (takes up to 1 hour to propagate)."
  echo "  To find the guild ID: right-click the server name → ${B}Copy ID${R}"
  echo
  local guild_id=""
  read -p "$(ask 'Guild ID (leave blank for global sync): ')" guild_id
  if [[ -n "${guild_id}" && ! "${guild_id}" =~ ^[0-9]{17,20}$ ]]; then
    warn "Invalid guild ID — ignoring (will use global sync)"
    guild_id=""
  fi
  echo

  # ------------------------------------------------------------------
  # 4. Discord server invite link (OPTIONAL)
  # ------------------------------------------------------------------
  echo -e "${B}Step 4 of 6 — Discord server invite link${R} ${YLW}(optional)${R}"
  echo "  This is the invite link to your community/support Discord server."
  echo "  It will be shown in the /about and /help commands so users know where to get help."
  echo "  Example: https://discord.gg/your-invite-code"
  echo "  Leave blank to skip (no invite will be displayed)."
  echo
  local discord_invite=""
  read -p "$(ask 'Discord server invite link (leave blank to skip): ')" discord_invite
  echo

  # ------------------------------------------------------------------
  # 5. Brand name (OPTIONAL, default: ZenVPS)
  # ------------------------------------------------------------------
  echo -e "${B}Step 5 of 6 — Brand name${R} ${YLW}(optional, default: ZenVPS)${R}"
  echo "  This name appears in Discord embeds, MOTD, and log messages."
  echo "  Must start with a letter/number and contain only [A-Za-z0-9_. -] (max 63 chars)."
  echo
  local brand="ZenVPS" input=""
  read -p "$(ask "Brand name [${brand}]: ")" input
  if [[ -n "${input}" ]]; then
    if [[ "${input}" =~ ^[A-Za-z0-9][A-Za-z0-9_.\-[:space:]]{0,62}$ ]]; then
      brand="${input}"
    else
      warn "Invalid brand name — using default (ZenVPS)"
    fi
  fi
  echo

  # ------------------------------------------------------------------
  # 6. Max VPS per user (OPTIONAL, default: 2)
  # ------------------------------------------------------------------
  echo -e "${B}Step 6 of 6 — Max VPS per user${R} ${YLW}(optional, default: 2)${R}"
  echo "  How many VPS containers a single Discord user can own."
  echo "  Set higher for trusted communities, lower for public bots."
  echo
  local max_vps="2"
  read -p "$(ask "Max VPS per user [${max_vps}]: ")" input
  if [[ -n "${input}" ]]; then
    if [[ "${input}" =~ ^[0-9]+$ ]] && [[ "${input}" -ge 1 ]] && [[ "${input}" -le 100 ]]; then
      max_vps="${input}"
    else
      warn "Invalid number — using default (2)"
    fi
  fi
  echo

  # ------------------------------------------------------------------
  # Summary
  # ------------------------------------------------------------------
  echo -e "${GRY}────────────────────────────────────────────────────────${R}"
  echo -e "${B}Summary:${R}"
  echo "  Bot token:        ${GRN}set (hidden)${R}"
  echo "  Owner ID(s):      ${CYN}${owner_ids}${R}"
  echo "  Guild ID:         ${CYN}${guild_id:-<none — global sync>}${R}"
  echo "  Discord invite:   ${CYN}${discord_invite:-<none>}${R}"
  echo "  Brand name:       ${CYN}${brand}${R}"
  echo "  Max VPS/user:     ${CYN}${max_vps}${R}"
  echo -e "${GRY}────────────────────────────────────────────────────────${R}"
  echo

  read -p "$(ask 'Save this configuration? [Y/n]: ')" confirm
  if [[ "${confirm}" =~ ^[Nn]$ ]]; then
    warn "Configuration discarded."
    return 1
  fi

  info "Writing configuration to ${env_file}…"
  sed -i \
    -e "s|^DISCORD_TOKEN=.*|DISCORD_TOKEN=${token}|" \
    -e "s|^OWNER_IDS=.*|OWNER_IDS=${owner_ids}|" \
    -e "s|^GUILD_ID=.*|GUILD_ID=${guild_id}|" \
    -e "s|^BRAND_NAME=.*|BRAND_NAME=${brand}|" \
    -e "s|^MAX_VPS_PER_USER=.*|MAX_VPS_PER_USER=${max_vps}|" \
    "${env_file}"

  if grep -q "^SUPPORT_DISCORD_INVITE=" "${env_file}"; then
    sed -i "s|^SUPPORT_DISCORD_INVITE=.*|SUPPORT_DISCORD_INVITE=${discord_invite}|" "${env_file}"
  else
    echo "SUPPORT_DISCORD_INVITE=${discord_invite}" >> "${env_file}"
  fi

  chmod 0600 "${env_file}"
  ok "Configuration saved"

  echo
  info "Next steps:"
  echo "  1. Start the bot:        ${CYN}sudo systemctl start zenvps${R}"
  echo "  2. Check status:         ${CYN}sudo zenvps status${R}"
  echo "  3. View live logs:       ${CYN}sudo zenvps logs -f${R}"
  echo "  4. Edit more settings:   ${CYN}sudo nano ${env_file}${R}"
  echo
  info "Invite the bot to your server with the OAuth2 URL generator at:"
  echo "  ${CYN}https://discord.com/developers/applications → Your app → OAuth2 → URL Generator${R}"
  echo "  Scopes: ${B}bot applications.commands${R}"
  echo "  Permissions: ${B}Send Messages, Embed Links, Read Message History${R}"
}

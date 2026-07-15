#!/bin/bash
# ZenVPS bot — installer
# Made by ZentrixDev
#
# Usage:
#   sudo bash install.sh install     # fresh install (git-clones source from GitHub)
#   sudo bash install.sh update      # git-pull latest source and restart
#   sudo bash install.sh uninstall   # stop and remove (keeps data + backups)
#   sudo bash install.sh repair      # reinstall deps + service files
#   sudo bash install.sh status      # show status
#   sudo bash install.sh wizard      # re-run the setup wizard
#
# Env vars:
#   ZENVPS_REPO_URL  override the default GitHub repo to clone from
#                     (default: https://github.com/ZentrixDev/ZenVPS-Files.git)
#   ZENVPS_SRC       use a local source directory instead of git-clone
#                     (e.g. /path/to/ZenVPS-Files/python)
#
# Supported OS: Ubuntu LTS and Debian stable only.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  R='\033[0m' B='\033[1m' RED='\033[31m' GRN='\033[32m' YLW='\033[33m'
  BLU='\033[34m' MAG='\033[35m' CYN='\033[36m' GRY='\033[90m'
else
  R='' B='' RED='' GRN='' YLW='' BLU='' MAG='' CYN='' GRY=''
fi

ok()    { echo -e "${GRN}✓${R} $*"; }
err()   { echo -e "${RED}✗${R} $*" >&2; }
warn()  { echo -e "${YLW}⚠${R} $*" >&2; }
info()  { echo -e "${BLU}ℹ${R}  $*"; }
step()  { echo -e "${MAG}▶${R} ${B}$*${R}"; }
ask()   { printf "${CYN}?${R}  %s" "$*"; }

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/zenvps"
CONFIG_DIR="/etc/zenvps"
DATA_DIR="/var/lib/zenvps"
LOG_DIR="/var/log/zenvps"
BACKUP_DIR="/var/lib/zenvps/backups"
RUN_USER="zenvps"
SERVICE_NAME="zenvps"
ASSUME_YES=0

# Where to git-clone the bot source from.  Can be overridden by:
#   1. $ZENVPS_REPO_URL env var (highest priority)
#   2. Interactive prompt during install (if TTY)
#   3. The default below
DEFAULT_REPO_URL="https://github.com/ZentrixDev/ZenVPS-Files.git"
REPO_URL="${ZENVPS_REPO_URL:-${DEFAULT_REPO_URL}}"

# Source library helpers
# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/lib/helpers.sh"

# Track everything we create for rollback on failure
ROLLBACK_LOG=""
trap 'on_error "${BASH_LINENO[0]}" "${BASH_SOURCE[0]}" "${LINENO}"' ERR

on_error() {
  local src="$2" line_no="$3"
  err "Error at ${src}:${line_no}: ${BASH_COMMAND}"
  if [[ -n "${ROLLBACK_LOG:-}" ]] && [[ -f "${ROLLBACK_LOG}" ]]; then
    warn "Rolling back changes…"
    rollback_apply "${ROLLBACK_LOG}"
  fi
  err "Installation failed. Check ${LOG_DIR}/zenvps-install.log"
  exit 1
}

install_log() {
  mkdir -p "${LOG_DIR}" 2>/dev/null || true
  echo "$(date '+%Y-%m-%d %H:%M:%S') │ $*" >> "${LOG_DIR}/zenvps-install.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${B}ZenVPS installer${R} v${VERSION} — Made by ZentrixDev

${B}Usage:${R}
  sudo bash install.sh <command> [options]

${B}Commands:${R}
  install     Fresh install
  update      Pull latest source and restart
  uninstall   Stop service and remove files (keeps data + backups)
  repair      Reinstall dependencies and re-sync service files
  status      Show service status
  wizard      Re-run the interactive setup wizard

${B}Options:${R}
  --yes       Skip confirmation prompts
  --help      Show this help

${B}Examples:${R}
  sudo bash install.sh install
  sudo bash install.sh wizard
  sudo bash install.sh status
EOF
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight() {
  step "Running pre-flight checks…"

  if [[ $EUID -ne 0 ]]; then
    err "This installer must be run as root (use sudo)."
    exit 1
  fi

  # OS detection
  if [[ ! -f /etc/os-release ]]; then
    err "Cannot detect OS — /etc/os-release not found."
    exit 1
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION="${VERSION_ID:-}"
  OS_PRETTY="${PRETTY_NAME:-${NAME:-unknown} ${VERSION_ID:-}}"

  info "Detected OS: ${OS_PRETTY}"
  install_log "OS=${OS_PRETTY} id=${OS_ID} version=${OS_VERSION}"

  case "${OS_ID}" in
    ubuntu)
      case "${OS_VERSION}" in
        20.04|22.04|24.04) ;;
        *) warn "Ubuntu ${OS_VERSION} is not an LTS release — install may fail" ;;
      esac
      ;;
    debian)
      case "${OS_VERSION}" in
        11|12) ;;
        *) warn "Debian ${OS_VERSION} is not a stable release — install may fail" ;;
      esac
      ;;
    *)
      err "Unsupported OS. This installer supports only Ubuntu LTS and Debian stable."
      err "Detected: ${OS_PRETTY}"
      err "See docs/INSTALL.md for manual installation on other systems."
      exit 1
      ;;
  esac

  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64|amd64) info "Architecture: x86_64" ;;
    aarch64|arm64) info "Architecture: arm64" ;;
    *) err "Unsupported architecture: ${ARCH}"; exit 1 ;;
  esac

  ok "Pre-flight checks passed"
}

# ---------------------------------------------------------------------------
# Command: install
# ---------------------------------------------------------------------------
cmd_install() {
  preflight

  clear
  echo -e "${B}${MAG}╔══════════════════════════════════════════╗${R}"
  echo -e "${B}${MAG}║       ZenVPS Bot Installer v${VERSION}       ║${R}"
  echo -e "${B}${MAG}║          Made by ZentrixDev              ║${R}"
  echo -e "${B}${MAG}╚══════════════════════════════════════════╝${R}"
  echo
  echo "Create your own free VPS hosting via Discord!"
  echo
  echo "This installer will:"
  echo "  • Install Python 3, Docker, git, and system dependencies"
  echo "  • Clone the ZenVPS source code from GitHub"
  echo "  • Build the Ubuntu and Debian VPS Docker images"
  echo "  • Set up a systemd service (auto-start on boot)"
  echo "  • Configure log rotation and a watchdog"
  echo "  • Ask for your Discord bot token and owner info"
  echo "  • Start the bot"
  echo

  if [[ "${ASSUME_YES}" != "1" ]]; then
    read -p "$(ask 'Are you sure you want to continue? (y/n): ')" -n 1 -r REPLY
    echo
    if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
      echo "Installation aborted."
      exit 1
    fi
  fi

  ROLLBACK_LOG="$(mktemp /tmp/zenvps-rollback.XXXXXX.log)"
  install_log "Starting ZenVPS install (repo=${REPO_URL})"

  # ------------------------------------------------------------------
  clear
  step "Step 1/9 — Installing system dependencies"
  echo
  install_system_deps
  ok "System dependencies installed"

  # ------------------------------------------------------------------
  clear
  step "Step 2/9 — Creating service user and directories"
  echo
  create_user_and_dirs
  ok "User and directories ready"

  # ------------------------------------------------------------------
  clear
  step "Step 3/9 — Acquiring ZenVPS source code"
  echo
  acquire_source
  ok "Source code ready at ${INSTALL_DIR}"

  # ------------------------------------------------------------------
  clear
  step "Step 4/9 — Installing Python runtime"
  echo
  install_python_runtime
  ok "Python runtime ready"

  # ------------------------------------------------------------------
  clear
  step "Step 5/9 — Building VPS Docker images"
  echo
  build_vps_images
  ok "Docker images built"

  # ------------------------------------------------------------------
  clear
  step "Step 6/9 — Setting up configuration"
  echo
  setup_config
  ok "Configuration ready at ${CONFIG_DIR}/env"

  # ------------------------------------------------------------------
  clear
  step "Step 7/9 — Installing systemd service"
  echo
  install_service
  ok "systemd service installed"

  # ------------------------------------------------------------------
  clear
  step "Step 8/9 — Running health checks"
  echo
  run_health_checks
  ok "Health checks passed"

  # ------------------------------------------------------------------
  clear
  step "Step 9/9 — Starting the bot"
  echo
  info "Starting ${SERVICE_NAME} service…"
  systemctl start "${SERVICE_NAME}"
  sleep 2

  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok "${SERVICE_NAME} is running"
  else
    err "Service did not start. Check: journalctl -u ${SERVICE_NAME} -n 50"
    exit 1
  fi

  echo
  echo -e "${B}${GRN}╔══════════════════════════════════════════╗${R}"
  echo -e "${B}${GRN}║       ✓ Installation Complete!           ║${R}"
  echo -e "${B}${GRN}╚══════════════════════════════════════════╝${R}"
  echo
  echo -e "${B}Next steps:${R}"
  echo "  1. Check status:   ${CYN}sudo zenvps status${R}"
  echo "  2. View live logs: ${CYN}sudo zenvps logs -f${R}"
  echo "  3. Edit config:    ${CYN}sudo nano ${CONFIG_DIR}/env${R}"
  echo "  4. Restart:        ${CYN}sudo zenvps restart${R}"
  echo
  echo -e "${B}Invite the bot to your Discord server:${R}"
  echo "  ${CYN}https://discord.com/developers/applications${R}"
  echo "  → Your app → OAuth2 → URL Generator"
  echo "  Scopes: bot, applications.commands"
  echo "  Permissions: Send Messages, Embed Links, Read Message History"
  echo
  ok "Happy hosting!"

  rm -f "${ROLLBACK_LOG}"
  ROLLBACK_LOG=""
}

# ---------------------------------------------------------------------------
# Command: update
# ---------------------------------------------------------------------------
cmd_update() {
  preflight
  clear
  step "Updating ZenVPS bot"
  info "Current version: $(get_installed_version 2>/dev/null || echo 'unknown')"

  # Backup before update
  if [[ -x /usr/local/bin/zenvps ]]; then
    info "Creating pre-update backup…"
    /usr/local/bin/zenvps backup || warn "Backup failed; continuing anyway"
  fi

  info "Stopping service…"
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true

  clear
  step "Pulling latest source code"
  update_source

  clear
  step "Reinstalling Python dependencies"
  install_python_runtime

  clear
  step "Rebuilding Docker images"
  build_vps_images

  clear
  step "Restarting service"
  systemctl start "${SERVICE_NAME}"
  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok "Update complete! Version: $(get_installed_version)"
  else
    err "Service failed to restart. Check: journalctl -u ${SERVICE_NAME} -n 50"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Command: uninstall
# ---------------------------------------------------------------------------
cmd_uninstall() {
  preflight
  clear
  step "Uninstalling ZenVPS bot"
  warn "This will stop the service and remove all bot files."
  warn "Your VPS data and backups will be PRESERVED in:"
  warn "  • ${DATA_DIR}"
  warn "  • ${BACKUP_DIR}"
  warn "  • ${CONFIG_DIR}"
  echo

  if [[ "${ASSUME_YES}" != "1" ]]; then
    read -p "$(ask 'Proceed with uninstall? (y/n): ')" -n 1 -r REPLY
    echo
    if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
      info "Uninstall cancelled."
      exit 0
    fi
  fi

  info "Stopping service…"
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

  info "Removing service files…"
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  rm -f "/etc/systemd/system/${SERVICE_NAME}-watchdog.service"
  rm -f "/etc/systemd/system/${SERVICE_NAME}-watchdog.timer"
  rm -f "/etc/systemd/system/${SERVICE_NAME}-anti-abuse.service"
  rm -f /etc/logrotate.d/zenvps
  systemctl daemon-reload

  info "Removing CLI tool…"
  rm -f /usr/local/bin/zenvps

  info "Removing source code…"
  rm -rf "${INSTALL_DIR}"

  info "Removing Docker images…"
  docker images --format '{{.Repository}}:{{.Tag}}' | grep '^zenvps/' | xargs -r docker rmi -f 2>/dev/null || true

  clear
  ok "Uninstall complete."
  info "Preserved:"
  echo "  • Data:       ${DATA_DIR}"
  echo "  • Backups:    ${BACKUP_DIR}"
  echo "  • Config:     ${CONFIG_DIR}"
  echo "  • Logs:       ${LOG_DIR}"
  echo "  • Service user: ${RUN_USER}"
  echo
  info "To remove everything: sudo rm -rf ${DATA_DIR} ${BACKUP_DIR} ${CONFIG_DIR} ${LOG_DIR} && sudo userdel ${RUN_USER}"
}

# ---------------------------------------------------------------------------
# Command: repair
# ---------------------------------------------------------------------------
cmd_repair() {
  preflight
  clear
  step "Repairing ZenVPS bot installation"

  info "Step 1/5: Verifying dependencies"
  install_system_deps
  install_python_runtime

  info "Step 2/5: Updating source code"
  update_source

  info "Step 3/5: Reinstalling service files"
  install_service

  info "Step 4/5: Rebuilding Docker images"
  build_vps_images

  info "Step 5/5: Restarting service"
  systemctl restart "${SERVICE_NAME}"
  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok "Repair complete — service is running."
  else
    err "Service is still failing. Check: journalctl -u ${SERVICE_NAME} -n 50"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Command: status
# ---------------------------------------------------------------------------
cmd_status() {
  clear
  echo -e "${B}ZenVPS — status${R}"
  echo
  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    echo "  Service:   ${GRN}● running${R}"
  else
    echo "  Service:   ${RED}● stopped${R}"
  fi
  echo "  Version:   $(get_installed_version 2>/dev/null || echo 'not installed')"
  echo "  Install:   ${INSTALL_DIR}"
  echo "  Config:    ${CONFIG_DIR}/env"
  echo "  Data:      ${DATA_DIR}"
  echo "  Logs:      ${LOG_DIR}"
  echo "  Backups:   ${BACKUP_DIR}"
  echo

  if command -v docker >/dev/null 2>&1; then
    count="$(docker ps -q --filter "label=zenvps.managed=true" 2>/dev/null | wc -l)"
    echo "  Docker:    ${GRN}available${R} (${count} managed container(s))"
  else
    echo "  Docker:    ${RED}not installed${R}"
  fi
  echo

  if [[ -f "${CONFIG_DIR}/env" ]]; then
    if grep -q '^DISCORD_TOKEN=$' "${CONFIG_DIR}/env" 2>/dev/null; then
      warn "DISCORD_TOKEN is empty — bot will not start until you set it."
      info "Run: sudo bash install.sh wizard"
    else
      ok "DISCORD_TOKEN is set"
    fi
  else
    warn "No config file at ${CONFIG_DIR}/env"
  fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
create_user_and_dirs() {
  if id "${RUN_USER}" &>/dev/null; then
    info "User '${RUN_USER}' already exists"
  else
    info "Creating system user '${RUN_USER}'"
    useradd --system --no-create-home --shell /usr/sbin/nologin "${RUN_USER}"
    rollback_record "userdel ${RUN_USER}"
  fi

  info "Creating directories"
  for d in "${INSTALL_DIR}" "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${BACKUP_DIR}" "${DATA_DIR}/keys" "${DATA_DIR}/temp"; do
    mkdir -p "${d}"
    chown "${RUN_USER}:${RUN_USER}" "${d}"
    chmod 0750 "${d}"
    rollback_record "rmdir '${d}' 2>/dev/null || true"
  done
  chown root:root "${CONFIG_DIR}"
  chmod 0750 "${CONFIG_DIR}"
}

setup_config() {
  local env_file="${CONFIG_DIR}/env"
  if [[ -f "${env_file}" ]]; then
    info "Config file already exists at ${env_file} — leaving untouched"
    return
  fi

  info "Writing default config to ${env_file}"
  cp "${INSTALL_DIR}/.env.example" "${env_file}"
  chmod 0600 "${env_file}"
  chown root:"${RUN_USER}" "${env_file}"

  # Run the wizard if interactive
  if [[ "${ASSUME_YES}" != "1" ]] && [[ -t 0 ]]; then
    wizard_run "${env_file}"
  fi
}

get_installed_version() {
  if [[ -f "${INSTALL_DIR}/VERSION" ]]; then
    cat "${INSTALL_DIR}/VERSION"
  elif [[ -f "${INSTALL_DIR}/pyproject.toml" ]]; then
    grep -m1 'version' "${INSTALL_DIR}/pyproject.toml" | sed -E 's/.*version\s*=\s*"([^"]+)".*/\1/'
  else
    echo "unknown"
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    install|update|uninstall|repair|status|wizard) CMD="$1"; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "${CMD}" ]]; then
  usage
  exit 1
fi

case "${CMD}" in
  install)   cmd_install ;;
  update)    cmd_update ;;
  uninstall) cmd_uninstall ;;
  repair)    cmd_repair ;;
  status)    cmd_status ;;
  wizard)
    preflight
    wizard_run "${CONFIG_DIR}/env"
    ;;
esac

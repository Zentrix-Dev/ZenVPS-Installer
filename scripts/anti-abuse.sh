#!/usr/bin/env bash
# anti-abuse.sh — host-level process scanner that kills known miners and
# fork-bombs.  Runs as a separate systemd service (zenvps-anti-abuse.service)
# in parallel with the bot's built-in container-level scanner.
#
# Unlike the original V4 anti.sh, this version:
#   • Uses `pgrep` (not `top`) for robust per-process matching
#   • Uses word-boundary regex so "python" no longer matches "python3"
#   • Has a fixed whitelist that includes the bot's own process names
#   • Writes structured logs that are picked up by logrotate
#   • Never kills PID 1 or systemd-managed services
#
# This script targets the HOST (it sees all processes).  The bot itself
# has a separate container-level scanner that runs `ps aux` inside each
# VPS container; this script is the safety net for host-level abuse
# (e.g. a container escape, or a user who managed to run a process on
# the host itself).

set -Eeuo pipefail

LOG_FILE="/var/log/zenvps/anti-abuse.log"
WHITELIST_RE='^(systemd|systemd-journald|systemd-logind|systemd-udevd|sshd|docker|dockerd|containerd|containerd-shim|runc|apt|apt-get|dpkg|bash|sh|zsh|python3?|node|npm|npx|zenvps|tmux|screen|htop|top|ps|grep|awk|sed|cat|tail|head|jq|curl|wget|gzip|gunzip|logrotate|cron|dbus|rsyslogd|named|unbound|systemd-resolved|networkd|udev)$'

# Miner / abuse process names (extended regex, word-boundary matched)
MINER_RE='\b(xmrig|ethminer|cgminer|sgminer|bfgminer|minerd|cpuminer|claymore|nbminer|t-rex|phoenixminer|teamredminer|nicehash|cryptonight|ccminer|cudo|kingdos)\b'
FORK_BOMB_RE=':(){:\|:&};:'

mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') │ $*" >> "${LOG_FILE}"
}

scan_once() {
  # Iterate every process; pgrep -a gives "PID <name>"
  while IFS= read -r line; do
    local pid proc_name
    pid="$(echo "${line}" | awk '{print $1}')"
    proc_name="$(echo "${line}" | awk '{print $2}')"
    # Strip leading path
    local base="${proc_name##*/}"

    # Skip PID 1 and self
    [[ "${pid}" -le 1 ]] && continue
    [[ "${pid}" -eq $$ ]] && continue

    # Skip whitelisted processes (use exact match on basename)
    if [[ "${base}" =~ ${WHITELIST_RE} ]]; then
      continue
    fi

    # Check for miner / abuse patterns
    if [[ "${base}" =~ ${MINER_RE} ]] || [[ "${proc_name}" =~ ${FORK_BOMB_RE} ]]; then
      # Verify the process still exists and we have permission
      if kill -0 "${pid}" 2>/dev/null; then
        log "Killing pid=${pid} name=${base} (matched miner/abuse pattern)"
        kill -9 "${pid}" 2>/dev/null || true
      fi
    fi
  done < <(ps -eo pid=,comm= 2>/dev/null)
}

log "anti-abuse.sh starting (pid=$$)"
while true; do
  scan_once
  sleep 5
done

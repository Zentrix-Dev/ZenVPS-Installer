#!/usr/bin/env bash
# egress-filter.sh — block outbound traffic to known mining-pool endpoints.
#
# Uses nftables if available, otherwise falls back to iptables.  Idempotent:
# re-running the script removes the existing zenvps chain and re-creates it.
#
# The blocklist is a curated list of known stratum+tcp endpoints and
# mining-pool domains.  It is NOT exhaustive — it is a defense-in-depth layer
# to complement the bot's container-level process scanner.
#
# Run this script as root.  The installer does NOT enable it by default;
# set EGRESS_FILTER_ENABLED=true in /etc/zenvps/env and run it manually:
#
#   sudo /var/lib/zenvps/egress-filter.sh install
#   sudo /var/lib/zenvps/egress-filter.sh remove

set -Eeuo pipefail

# Curated blocklist of known mining pool domains (June 2026 snapshot).
# Update periodically from https://github.com/hagezi/dns-blocklists
BLOCKLIST_DOMAINS=(
  # Major mining pools
  "pool.minexmr.com"
  "pool.supportxmr.com"
  "xmr.pool.minergate.com"
  "monero.crypto-pool.fr"
  "xmrpool.eu"
  "monero.hashvault.pro"
  "pool.hashvault.pro"
  "moneroocean.stream"
  "gulf.moneroocean.stream"
  "xmr.2miners.com"
  "xmr.2miners.ru"
  "moneropool.com"
  "miner.rocks"
  "monero.miningpoolhub.com"
  "nanopool.org"
  "eth.nanopool.org"
  "etc.nanopool.org"
  "zec.nanopool.org"
  "xmr.nanopool.org"
  "rvn.nanopool.org"
  "eth.2miners.com"
  "etc.2miners.com"
  "zec.2miners.com"
  "xzc.2miners.com"
  "kaw.2miners.com"
  "firo.2miners.com"
  "pool.ethermine.org"
  "asia1.ethermine.org"
  "eu1.ethermine.org"
  "us1.ethermine.org"
  "us2.ethermine.org"
  "flypool.org"
  "eth-us-east1.flypool.org"
  "eth-us-west1.flypool.org"
  "eth-eu1.flypool.org"
  "eth-asia1.flypool.org"
  "dwarfpool.com"
  "eth-eu.dwarfpool.com"
  "eth-us.dwarfpool.com"
  "eth-asia.dwarfpool.com"
  "f2pool.com"
  "antpool.com"
  "btc.antpool.com"
  "eth.antpool.com"
  "ltc.antpool.com"
  "viabtc.com"
  "btc.viabtc.com"
  "eth.viabtc.com"
  "ltc.viabtc.com"
  "btccom.com"
  "pool.btc.com"
  "eth.pool.btc.com"
  "sparkpool.com"
  "eth.sparkpool.com"
  "beepool.org"
  "flexpool.io"
  "eth.flexpool.io"
  "cruxpool.com"
  "eth.cruxpool.com"
)

# Known stratum ports to block (regardless of destination)
STRATUM_PORTS=(3333 4444 5555 7777 9000 14433 14444 14444 3355)

CHAIN_NAME="ZENVPS-EGRESS"

use_nftables() {
  command -v nft &>/dev/null && nft list table inet filter &>/dev/null
}

cmd_install() {
  echo "Installing egress filter…"
  if use_nftables; then
    install_nft
  else
    install_iptables
  fi
  echo "Done. $(echo "${BLOCKLIST_DOMAINS[@]}" | wc -w) domains and ${#STRATUM_PORTS[@]} stratum ports blocked."
}

cmd_remove() {
  echo "Removing egress filter…"
  if use_nftables; then
    nft delete table inet zenvps_egress 2>/dev/null || true
  else
    iptables -D OUTPUT -j "${CHAIN_NAME}" 2>/dev/null || true
    iptables -F "${CHAIN_NAME}" 2>/dev/null || true
    iptables -X "${CHAIN_NAME}" 2>/dev/null || true
  fi
  echo "Done."
}

install_nft() {
  # Recreate the table from scratch
  nft delete table inet zenvps_egress 2>/dev/null || true
  nft add table inet zenvps_egress
  nft add chain inet zenvps_egress output '{ type filter hook output priority -10; policy accept; }'

  # Block known stratum ports regardless of destination
  for port in "${STRATUM_PORTS[@]}"; do
    nft add rule inet zenvps_egress output tcp dport "${port}" drop comment "zenvps stratum block"
  done

  # Resolve and block each domain
  local resolved_ips=()
  for domain in "${BLOCKLIST_DOMAINS[@]}"; do
    # getent is more portable than dig
    while IFS= read -r ip; do
      [[ "${ip}" =~ ^[0-9.]+$ ]] && resolved_ips+=("${ip}")
    done < <(getent hosts "${domain}" 2>/dev/null | awk '{print $1}')
  done

  # Dedupe
  mapfile -t resolved_ips < <(printf '%s\n' "${resolved_ips[@]}" | sort -u)

  for ip in "${resolved_ips[@]}"; do
    nft add rule inet zenvps_egress output ip daddr "${ip}" drop comment "zenvps miner pool block"
  done

  echo "  nftables: $(nft list table inet zenvps_egress | grep -c 'drop') rules installed"
}

install_iptables() {
  # Clean any previous chain
  iptables -D OUTPUT -j "${CHAIN_NAME}" 2>/dev/null || true
  iptables -F "${CHAIN_NAME}" 2>/dev/null || true
  iptables -X "${CHAIN_NAME}" 2>/dev/null || true

  iptables -N "${CHAIN_NAME}"

  for port in "${STRATUM_PORTS[@]}"; do
    iptables -A "${CHAIN_NAME}" -p tcp --dport "${port}" -j DROP -m comment --comment "zenvps stratum"
  done

  for domain in "${BLOCKLIST_DOMAINS[@]}"; do
    while IFS= read -r ip; do
      [[ "${ip}" =~ ^[0-9.]+$ ]] && iptables -A "${CHAIN_NAME}" -d "${ip}" -j DROP -m comment --comment "zenvps pool"
    done < <(getent hosts "${domain}" 2>/dev/null | awk '{print $1}')
  done

  iptables -A OUTPUT -j "${CHAIN_NAME}"
  echo "  iptables: $(iptables -L "${CHAIN_NAME}" -n | grep -c DROP) rules installed"
}

case "${1:-install}" in
  install|add) cmd_install ;;
  remove|delete|uninstall) cmd_remove ;;
  list)
    if use_nftables; then
      nft list table inet zenvps_egress
    else
      iptables -L "${CHAIN_NAME}" -n -v
    fi
    ;;
  *)
    echo "Usage: $0 {install|remove|list}"
    exit 1
    ;;
esac

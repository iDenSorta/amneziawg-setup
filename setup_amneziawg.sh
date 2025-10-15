#!/usr/bin/env bash
set -euo pipefail

# ===============================================
# AmneziaWG Easy setup (interaction all at start)
# ===============================================

# --------- Config / Prompt all inputs at start ----------
DEFAULT_WG_PORT="53100"
DEFAULT_WG_ADDR="10.48.0.x"

prompt_if_empty() {
  local varname="$1"; local prompt="$2"; local default="${3:-}"
  local value="${!varname:-}"
  if [ -n "$value" ]; then
    echo "$varname is set in environment -> $([ "$varname" = "WEB_PASS" ] && echo "(hidden)" || echo "$value")"
    export "$varname"="$value"
    return 0
  fi

  if [ -t 0 ]; then
    if [ -n "$default" ]; then
      read -rp "$prompt [$default]: " value
      value="${value:-$default}"
    else
      read -rp "$prompt: " value
    fi
    export "$varname"="$value"
  else
    echo "Error: $varname not provided and not running interactively." >&2
    exit 1
  fi
}

# Collect all inputs up-front
prompt_if_empty "WG_HOST" "Enter SERVER IP (WG_HOST)" ""
prompt_if_empty "WG_PORT" "Enter UDP port for clients (WG_PORT)" "$DEFAULT_WG_PORT"
prompt_if_empty "WG_DEFAULT_ADDRESS" "Enter client subnet (WG_DEFAULT_ADDRESS)" "$DEFAULT_WG_ADDR"

# WEB_PASS read hidden if not provided
if [ -z "${WEB_PASS:-}" ]; then
  if [ -t 0 ]; then
    read -rs -p "Enter WEB UI password (will be hashed with bcrypt): " WEB_PASS
    echo
    if [ -z "$WEB_PASS" ]; then
      echo "Password cannot be empty." >&2
      exit 1
    fi
    export WEB_PASS
  else
    echo "Error: WEB_PASS not provided and not running interactively." >&2
    exit 1
  fi
else
  echo "WEB_PASS provided via environment (hidden)."
fi

# Validate inputs
if ! [[ "$WG_PORT" =~ ^[0-9]+$ ]]; then
  echo "WG_PORT must be an integer." >&2
  exit 1
fi
if [ "$WG_PORT" -lt 1024 ] || [ "$WG_PORT" -gt 65535 ]; then
  echo "WG_PORT must be between 1024 and 65535." >&2
  exit 1
fi
if [ -z "${WG_HOST}" ]; then
  echo "WG_HOST is required." >&2
  exit 1
fi

echo "=== Configuration (review) ==="
echo "WG_HOST=$WG_HOST"
echo "WG_PORT=$WG_PORT"
echo "WG_DEFAULT_ADDRESS=$WG_DEFAULT_ADDRESS"
echo "=============================="

# --------- Non-interactive execution ----------
ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use: sudo bash $0" >&2
    exit 1
  fi
}
ensure_root

wait_for_apt() {
  echo "Checking APT locks..."
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 ||         fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ||         pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null; do
    echo "APT is busy, waiting 2s..."
    sleep 2
  done
  echo "No APT locks detected. Proceeding..."
}

install_if_missing() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "Installing $pkg ..."
    wait_for_apt
    apt-get update -y
    apt-get install -y "$pkg"
  else
    echo "$pkg already installed."
  fi
}

# Ensure dependencies
wait_for_apt
if ! command -v curl >/dev/null 2>&1; then
  install_if_missing curl
else
  echo "curl found."
fi

if ! command -v htpasswd >/dev/null 2>&1; then
  install_if_missing apache2-utils
else
  echo "apache2-utils (htpasswd) found."
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found. Installing via get.docker.com..."
  wait_for_apt
  curl -fsSL https://get.docker.com | sh
else
  echo "docker found."
fi

# Generate bcrypt hash
set +e
H="$(printf "%s
" "$WEB_PASS" | htpasswd -niB user | cut -d: -f2)"
ret=$?
set -e
if [ "$ret" -ne 0 ] || [ -z "$H" ]; then
  echo "Failed to generate bcrypt hash." >&2
  exit 1
fi
echo "Password hash generated."

# Stop & remove existing container
if docker ps -a --format '{{.Names}}' | grep -q '^amnezia-wg-easy$'; then
  echo "Existing container found. Stopping and removing..."
  docker stop amnezia-wg-easy || true
  docker rm amnezia-wg-easy || true
else
  echo "No existing container found."
fi

# Prepare data dir
DATA_DIR="/root/.amnezia-wg-easy"
mkdir -p "$DATA_DIR"
chown root:root "$DATA_DIR"

# Run container
echo "Launching amnezia-wg-easy container..."
docker run -d   --name amnezia-wg-easy   --cap-add=NET_ADMIN --cap-add=SYS_MODULE   --device=/dev/net/tun   -e WG_HOST="$WG_HOST"   -e WG_PORT="$WG_PORT"   -e WG_DEFAULT_ADDRESS="$WG_DEFAULT_ADDRESS"   -e PASSWORD_HASH="$H"   -v "$DATA_DIR":/etc/wireguard   -p "${WG_PORT}:${WG_PORT}/udp" -p 51821:51821/tcp   ghcr.io/w0rng/amnezia-wg-easy

echo "Container started. Waiting 3s for status..."
sleep 3
docker ps --filter "name=amnezia-wg-easy" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo "==============================================="
echo " AmneziaWG Easy deployed successfully!"
echo " Web UI:   http://$WG_HOST:51821"
echo " UDP Port: $WG_PORT"
echo " Subnet:   $WG_DEFAULT_ADDRESS"
echo " Configs dir: $DATA_DIR"
echo "==============================================="

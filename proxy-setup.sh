#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   scripts/setup_proxy.sh --users "u1:p1,u2:p2" [--port 3128] [--host example.com]
#   PROXY_USERS="u1:p1,u2:p2" PROXY_PORT=3128 scripts/setup_proxy.sh
#   scripts/setup_proxy.sh   # interactive mode if TTY and --users not provided

if [ "${EUID}" -ne 0 ]; then
  echo "ERROR: must be run as root"
  exit 1
fi

PROXY_NAME="${PROXY_NAME:-simple-proxy}"
PROXY_PORT="${PROXY_PORT:-}"
PROXY_USERS="${PROXY_USERS:-}"
PROXY_HOST="${PROXY_HOST:-}"
DATA_DIR="${DATA_DIR:-/root/.proxy-3proxy}"
PROXY_TEST_URL="${PROXY_TEST_URL:-https://ifconfig.me}"
PROXY_BANDWIDTH_MBIT="${PROXY_BANDWIDTH_MBIT:-10}"

usage() {
  echo "Usage: $0 --users \"u1:p1,u2:p2\" [--port 3128] [--host example.com] [--name simple-proxy] [--data-dir /root/.proxy-3proxy]"
  echo "Optional: --bandwidth-mbit 10 (limit for whole proxy, Mbps)"
  echo "If --port is omitted, a free port in the 20000-40000 range will be selected."
}

while [ $# -gt 0 ]; do
  case "$1" in
    --users)
      PROXY_USERS="$2"; shift 2; ;;
    --port)
      PROXY_PORT="$2"; shift 2; ;;
    --host)
      PROXY_HOST="$2"; shift 2; ;;
    --name)
      PROXY_NAME="$2"; shift 2; ;;
    --data-dir)
      DATA_DIR="$2"; shift 2; ;;
    --bandwidth-mbit)
      PROXY_BANDWIDTH_MBIT="$2"; shift 2; ;;
    -h|--help)
      usage; exit 0; ;;
    *)
      echo "ERROR: unknown argument: $1"; usage; exit 1; ;;
  esac
 done

if [ -z "${PROXY_USERS}" ]; then
  if [ -t 0 ]; then
    read -rp "How many users to create: " user_count
    if ! [[ "${user_count}" =~ ^[0-9]+$ ]] || [ "${user_count}" -le 0 ]; then
      echo "ERROR: invalid user count"; exit 1;
    fi
    entries=()
    for i in $(seq 1 "${user_count}"); do
      read -rp "User ${i} login: " login
      read -rp "User ${i} password: " pass
      if [ -z "${login}" ] || [ -z "${pass}" ]; then
        echo "ERROR: login/password cannot be empty"; exit 1;
      fi
      if [[ "${login}" == *:* ]] || [[ "${pass}" == *:* ]]; then
        echo "ERROR: ':' is not allowed in login or password"; exit 1;
      fi
      entries+=("${login}:${pass}")
    done
    PROXY_USERS="$(IFS=','; echo "${entries[*]}")"
  else
    echo "ERROR: PROXY_USERS is required (format: u1:p1,u2:p2)"; exit 1;
  fi
fi

if ! [[ "${PROXY_BANDWIDTH_MBIT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: PROXY_BANDWIDTH_MBIT must be numeric (Mbps)"; exit 1;
fi
PROXY_BANDWIDTH_BPS=$((PROXY_BANDWIDTH_MBIT * 1000 * 1000))

port_in_use() {
  local port="$1"
  ss -H -t -l -n | awk '{print $4}' | grep -Eq "(^|:|\\[):${port}($|[^0-9])"
}

pick_free_port() {
  local start=20000
  local end=40000
  local port
  for port in $(seq "${start}" "${end}"); do
    if ! port_in_use "${port}"; then
      echo "${port}"
      return 0
    fi
  done
  return 1
}

if [ -z "${PROXY_PORT}" ]; then
  PROXY_PORT="$(pick_free_port || true)"
  if [ -z "${PROXY_PORT}" ]; then
    echo "ERROR: no free TCP port found in 20000-40000"; exit 1;
  fi
fi

if ! [[ "${PROXY_PORT}" =~ ^[0-9]{2,5}$ ]]; then
  echo "ERROR: invalid PROXY_PORT"; exit 1;
fi

if port_in_use "${PROXY_PORT}"; then
  echo "ERROR: TCP port ${PROXY_PORT} already in use."; exit 1;
fi

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if ! command -v apt-get >/dev/null 2>&1; then
      echo "ERROR: docker not found and apt-get unavailable"; exit 1;
    fi
    DEBIAN_FRONTEND=noninteractive apt-get update -y -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl ca-certificates
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker || { echo "ERROR: Docker failed to start"; exit 1; }
  if ! systemctl is-active --quiet docker; then
    echo "ERROR: Docker not running"; exit 1;
  fi
}

if [ -z "${PROXY_HOST}" ]; then
  PROXY_HOST="$(hostname -I | awk '{print $1}')"
fi

if [[ "${PROXY_HOST}" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
  echo "NOTE: PROXY_HOST=${PROXY_HOST} (private address, not publicly reachable)"
fi

mkdir -p "${DATA_DIR}"
CONFIG_PATH="${DATA_DIR}/3proxy.cfg"

IFS=',' read -r -a USER_LIST <<< "${PROXY_USERS}"
if [ "${#USER_LIST[@]}" -eq 0 ]; then
  echo "ERROR: no users parsed from PROXY_USERS"; exit 1;
fi

users_line=""
allow_lines=""
for entry in "${USER_LIST[@]}"; do
  if ! [[ "${entry}" =~ ^[^:]+:.+$ ]]; then
    echo "ERROR: invalid user entry: ${entry} (expected user:pass)"; exit 1;
  fi
  username="${entry%%:*}"
  password="${entry#*:}"
  users_line+=" ${username}:CL:${password}"
  allow_lines+=$'allow '"${username}"$'\n'
done

umask 077
cat > "${CONFIG_PATH}" <<EOF_CONFIG
maxconn 200
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth strong
users${users_line}
EOF_CONFIG
printf '%s' "${allow_lines}" >> "${CONFIG_PATH}"
cat >> "${CONFIG_PATH}" <<EOF_CONFIG
bandlimin ${PROXY_BANDWIDTH_BPS} * *
bandlimout ${PROXY_BANDWIDTH_BPS} * *
proxy -p${PROXY_PORT} -a
EOF_CONFIG
chmod 600 "${CONFIG_PATH}" || true

ensure_docker

if docker ps -a --format '{{.Names}}' | grep -qx "${PROXY_NAME}"; then
  docker rm -f "${PROXY_NAME}" >/dev/null 2>&1 || true
fi

docker pull 3proxy/3proxy >/dev/null 2>&1 || true

docker run -d \
  --name "${PROXY_NAME}" \
  --restart unless-stopped \
  -p "${PROXY_PORT}:${PROXY_PORT}/tcp" \
  -v "${CONFIG_PATH}:/etc/3proxy/3proxy.cfg:ro" \
  3proxy/3proxy >/dev/null

sleep 2
state="$(docker inspect -f '{{.State.Status}}' "${PROXY_NAME}" 2>/dev/null || true)"
if [ "${state}" != "running" ]; then
  echo "ERROR: proxy container not running (state=${state:-unknown})"
  echo "Config:"
  nl -ba "${CONFIG_PATH}" || true
  echo "Logs:"
  docker logs "${PROXY_NAME}" --tail 50 || true
  exit 1
fi

if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -q "Status: active"; then
    ufw allow "${PROXY_PORT}/tcp" >/dev/null 2>&1 || true
  fi
fi

echo "READY: proxy running"
echo "ProxyHost=${PROXY_HOST}"
echo "ProxyPort=${PROXY_PORT}"
for entry in "${USER_LIST[@]}"; do
  echo "ProxyLogin=${entry%%:*}"
  echo "ProxyPass=${entry#*:}"
  echo "---"
done

first_user="${USER_LIST[0]%%:*}"
first_pass="${USER_LIST[0]#*:}"
if command -v curl >/dev/null 2>&1; then
  if curl -fsS -x "http://${first_user}:${first_pass}@127.0.0.1:${PROXY_PORT}" "${PROXY_TEST_URL}" >/dev/null; then
    echo "ProxyTest=ok"
  else
    echo "ProxyTest=failed (local check)"
  fi
else
  echo "ProxyTest=skipped (curl not installed)"
fi

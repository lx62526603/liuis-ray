#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_VERSION="0.1.0"
XRAY_INSTALL_COMMIT="e741a4f56d368afbb9e5be3361b40c4552d3710d"
XRAY_INSTALL_SHA256="7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555"
XRAY_INSTALL_URL="https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_COMMIT}/install-release.sh"

XRAY_PORT=443
REALITY_SERVER_NAME="www.microsoft.com"
REALITY_TARGET_PORT=443
PUBLIC_ADDRESS=""
NODE_NAME="xray-easy"
ENABLE_BBR=1
FORCE=0

STATE_DIR="/etc/xray-easy"
STATE_FILE="${STATE_DIR}/state.env"
CONFIG_FILE="/usr/local/etc/xray/config.json"
CLI_FILE="/usr/local/sbin/xray-easy"

log() { printf '\033[1;32m[xray-easy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[xray-easy] WARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[xray-easy] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash install.sh [options]

Options:
  --port PORT                 VLESS REALITY TCP port (default: 443)
  --server-name DOMAIN        REALITY SNI and target host (default: www.microsoft.com)
  --target-port PORT          REALITY target port (default: 443)
  --address HOST              Public IPv4 or domain placed in client links
  --name NAME                 ASCII node name (default: xray-easy)
  --no-bbr                    Do not enable fq + BBR
  --force                     Back up and replace a pre-existing unmanaged config
  -h, --help                  Show this help

Examples:
  sudo bash install.sh
  sudo bash install.sh --address 203.0.113.10 --name tokyo-1
EOF
}

is_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
is_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
is_ipv4() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip"
  [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}
while (( "$#" )); do
  case "$1" in
    --port) [[ $# -ge 2 ]] || die "--port requires a value"; XRAY_PORT="$2"; shift 2 ;;
    --server-name) [[ $# -ge 2 ]] || die "--server-name requires a value"; REALITY_SERVER_NAME="$2"; shift 2 ;;
    --target-port) [[ $# -ge 2 ]] || die "--target-port requires a value"; REALITY_TARGET_PORT="$2"; shift 2 ;;
    --address) [[ $# -ge 2 ]] || die "--address requires a value"; PUBLIC_ADDRESS="$2"; shift 2 ;;
    --name) [[ $# -ge 2 ]] || die "--name requires a value"; NODE_NAME="$2"; shift 2 ;;
    --no-bbr) ENABLE_BBR=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "Run this installer as root."
[[ "$(uname -s)" == "Linux" ]] || die "Only Linux is supported."
[[ -d /run/systemd/system ]] || die "A systemd-based VPS is required."
[[ -r /etc/os-release ]] || die "Cannot identify the operating system."
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) die "This release supports Debian 12+ and Ubuntu 22.04+ only (detected: ${ID:-unknown})." ;;
esac

is_port "$XRAY_PORT" || die "Invalid Xray port: $XRAY_PORT"
is_port "$REALITY_TARGET_PORT" || die "Invalid target port: $REALITY_TARGET_PORT"
is_domain "$REALITY_SERVER_NAME" || die "Invalid REALITY server name: $REALITY_SERVER_NAME"
[[ "$NODE_NAME" =~ ^[A-Za-z0-9._-]{1,48}$ ]] || die "Node name may contain only A-Z, a-z, 0-9, dot, underscore and hyphen."
if [[ -n "$PUBLIC_ADDRESS" ]]; then
  is_ipv4 "$PUBLIC_ADDRESS" || is_domain "$PUBLIC_ADDRESS" || die "--address must be an IPv4 address or domain."
fi
if [[ -f "$STATE_FILE" ]]; then
  die "xray-easy is already installed. Run 'xray-easy show' or remove ${STATE_FILE} only if you intend to rebuild it."
fi
if [[ -s "$CONFIG_FILE" && "$FORCE" -ne 1 ]]; then
  die "An unmanaged Xray config already exists at ${CONFIG_FILE}. Re-run with --force only after reviewing it."
fi

export DEBIAN_FRONTEND=noninteractive
log "Installing required packages..."
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssl qrencode

if [[ -z "$PUBLIC_ADDRESS" ]]; then
  PUBLIC_ADDRESS="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org || true)"
  is_ipv4 "$PUBLIC_ADDRESS" || die "Could not detect a public IPv4 address. Use --address."
fi

log "Checking whether the REALITY target supports TLS 1.3..."
if ! timeout 12 openssl s_client \
  -connect "${REALITY_SERVER_NAME}:${REALITY_TARGET_PORT}" \
  -servername "$REALITY_SERVER_NAME" \
  -tls1_3 -brief </dev/null >/dev/null 2>&1; then
  die "TLS 1.3 connection to ${REALITY_SERVER_NAME}:${REALITY_TARGET_PORT} failed. Choose another --server-name."
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

log "Downloading the pinned official XTLS installer..."
curl -fL --retry 3 --connect-timeout 15 \
  "$XRAY_INSTALL_URL" -o "${TMP_DIR}/xray-install.sh"
printf '%s  %s\n' "$XRAY_INSTALL_SHA256" "${TMP_DIR}/xray-install.sh" | sha256sum -c -

log "Installing/updating Xray through the official installer..."
bash "${TMP_DIR}/xray-install.sh" install
[[ -x /usr/local/bin/xray ]] || die "Xray installation did not produce /usr/local/bin/xray."

UUID="$(/usr/local/bin/xray uuid)"
KEY_OUTPUT="$(/usr/local/bin/xray x25519)"
PRIVATE_KEY="$(awk -F': ' '/^PrivateKey:/ {print $2; exit}' <<<"$KEY_OUTPUT")"
PUBLIC_KEY="$(awk -F': ' '/^(Password|PublicKey)( \(PublicKey\))?:/ {print $2; exit}' <<<"$KEY_OUTPUT")"
if [[ -z "$PUBLIC_KEY" ]]; then
  PUBLIC_KEY="$(sed -n '2{s/^[^:]*:[[:space:]]*//;p;}' <<<"$KEY_OUTPUT")"
fi
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "Could not parse the X25519 key pair generated by Xray."
SHORT_ID="$(openssl rand -hex 8)"

install -d -m 700 "$STATE_DIR"
if [[ -s "$CONFIG_FILE" ]]; then
  cp -a "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi

CONFIG_TMP="${TMP_DIR}/config.json"
cat >"$CONFIG_TMP" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "default"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_SERVER_NAME}:${REALITY_TARGET_PORT}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SERVER_NAME}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ]
}
EOF

/usr/local/bin/xray run -test -config "$CONFIG_TMP"
install -d -m 750 /usr/local/etc/xray
XRAY_USER="$(systemctl show xray.service -p User --value 2>/dev/null || true)"
XRAY_USER="${XRAY_USER:-nobody}"
XRAY_GROUP="$(id -gn "$XRAY_USER" 2>/dev/null || true)"
XRAY_GROUP="${XRAY_GROUP:-nogroup}"
install -o root -g "$XRAY_GROUP" -m 640 "$CONFIG_TMP" "$CONFIG_FILE"

save_initial_state() {
  {
    printf 'PROJECT_VERSION=%q\n' "$PROJECT_VERSION"
    printf 'XRAY_INSTALL_COMMIT=%q\n' "$XRAY_INSTALL_COMMIT"
    printf 'XRAY_INSTALL_SHA256=%q\n' "$XRAY_INSTALL_SHA256"
    printf 'XRAY_INSTALL_URL=%q\n' "$XRAY_INSTALL_URL"
    printf 'XRAY_PORT=%q\n' "$XRAY_PORT"
    printf 'REALITY_SERVER_NAME=%q\n' "$REALITY_SERVER_NAME"
    printf 'REALITY_TARGET_PORT=%q\n' "$REALITY_TARGET_PORT"
    printf 'PUBLIC_ADDRESS=%q\n' "$PUBLIC_ADDRESS"
    printf 'NODE_NAME=%q\n' "$NODE_NAME"
    printf 'UUID=%q\n' "$UUID"
    printf 'PUBLIC_KEY=%q\n' "$PUBLIC_KEY"
    printf 'SHORT_ID=%q\n' "$SHORT_ID"
  } >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
  chown root:root "$STATE_FILE"
}
save_initial_state

cat >"$CLI_FILE" <<'CLI_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STATE_FILE="/etc/xray-easy/state.env"
CONFIG_FILE="/usr/local/etc/xray/config.json"

log() { printf '\033[1;32m[xray-easy]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[xray-easy] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
need_root() { [[ "$(id -u)" -eq 0 ]] || die "This command must run as root."; }

load_state() {
  [[ -r "$STATE_FILE" ]] || die "State file not found: $STATE_FILE"
  # This file is created root-owned with mode 0600 by xray-easy.
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

build_uri() {
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$UUID" "$PUBLIC_ADDRESS" "$XRAY_PORT" "$REALITY_SERVER_NAME" "$PUBLIC_KEY" "$SHORT_ID" "$NODE_NAME"
}

show_config() {
  load_state
  local uri
  uri="$(build_uri)"
  cat <<EOF
Node:        ${NODE_NAME}
Server:      ${PUBLIC_ADDRESS}:${XRAY_PORT}
Protocol:    VLESS + REALITY + Vision
SNI:         ${REALITY_SERVER_NAME}

Share URI:
${uri}
EOF
}

show_qr() {
  load_state
  command -v qrencode >/dev/null || die "qrencode is not installed."
  qrencode -t ANSIUTF8 "$(build_uri)"
}

enable_bbr() {
  need_root
  modprobe tcp_bbr 2>/dev/null || true
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    die "This kernel does not expose BBR. Upgrade the VPS kernel and try again."
  fi
  cat >/etc/sysctl.d/99-xray-easy-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null
  [[ "$(sysctl -n net.core.default_qdisc)" == "fq" ]] || die "Failed to activate fq."
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] || die "Failed to activate BBR."
  log "fq + BBR is active."
}

update_xray() {
  need_root
  load_state
  local tmp
  tmp="$(mktemp)"
  curl -fL --retry 3 --connect-timeout 15 "$XRAY_INSTALL_URL" -o "$tmp"
  printf '%s  %s\n' "$XRAY_INSTALL_SHA256" "$tmp" | sha256sum -c -
  bash "$tmp" install
  rm -f "$tmp"
  /usr/local/bin/xray run -test -config "$CONFIG_FILE"
  systemctl restart xray
  systemctl --quiet is-active xray || die "Xray failed after the update."
  /usr/local/bin/xray version | head -n 1
}

usage() {
  cat <<'EOF'
Usage: xray-easy COMMAND

Commands:
  show                              Show the VLESS share URI
  qr                                Show a terminal QR code
  status                            Show Xray service status
  logs                              Show recent Xray logs
  restart                           Validate config and restart Xray
  update                            Update Xray using the pinned official installer
  bbr                               Enable and verify fq + BBR
EOF
}

case "${1:-show}" in
  show) show_config ;;
  qr) show_qr ;;
  status) systemctl --no-pager --full status xray ;;
  logs) journalctl --no-pager -e -u xray ;;
  restart)
    need_root
    /usr/local/bin/xray run -test -config "$CONFIG_FILE"
    systemctl restart xray
    systemctl --no-pager --full status xray
    ;;
  update) update_xray ;;
  bbr) enable_bbr ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
CLI_EOF
chmod 755 "$CLI_FILE"
chown root:root "$CLI_FILE"

install -d -m 755 /etc/systemd/system/xray.service.d
cat >/etc/systemd/system/xray.service.d/20-xray-easy-hardening.conf <<'EOF'
[Service]
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
RestrictSUIDSGID=true
LockPersonality=true
EOF

systemctl daemon-reload
/usr/local/bin/xray run -test -config "$CONFIG_FILE"
systemctl enable xray
systemctl restart xray
systemctl --quiet is-active xray || {
  journalctl --no-pager -n 50 -u xray >&2
  die "Xray failed to start."
}

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  log "UFW is active; opening ${XRAY_PORT}/tcp."
  ufw allow "${XRAY_PORT}/tcp"
else
  warn "No active UFW firewall detected. Also open TCP ${XRAY_PORT} in your VPS provider's security group."
fi

if [[ "$ENABLE_BBR" -eq 1 ]]; then
  if ! "$CLI_FILE" bbr; then
    warn "Xray is installed, but BBR could not be enabled on this kernel."
  fi
fi

printf '\n'
log "Installation completed."
"$CLI_FILE" show
printf '\nRun this at any time:\n  sudo xray-easy show\n  sudo xray-easy qr\n'

#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALLER_VERSION="0.4.0"

PINNED_XRAY_INSTALL_COMMIT="e741a4f56d368afbb9e5be3361b40c4552d3710d"
PINNED_XRAY_INSTALL_SHA256="7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555"
PINNED_HYSTERIA_VERSION="2.9.2"

XRAY_INSTALL_COMMIT="$PINNED_XRAY_INSTALL_COMMIT"
XRAY_INSTALL_SHA256="$PINNED_XRAY_INSTALL_SHA256"
XRAY_INSTALL_URL="https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_COMMIT}/install-release.sh"
HYSTERIA_VERSION="$PINNED_HYSTERIA_VERSION"
HYSTERIA_RELEASE_TAG="app%2Fv${HYSTERIA_VERSION}"

XRAY_PORT=443
HYSTERIA_PORT=443
REALITY_SERVER_NAME="www.microsoft.com"
REALITY_TARGET_PORT=443
HYSTERIA_SNI="www.cloudflare.com"
PUBLIC_ADDRESS=""
NODE_NAME="liuis-ray"
ENABLE_BBR=1
FORCE=0

ADDRESS_SET=0
NAME_SET=0
XRAY_PORT_SET=0
HYSTERIA_PORT_SET=0
SERVER_NAME_SET=0
TARGET_PORT_SET=0

STATE_DIR="/etc/liuis-ray"
STATE_FILE="${STATE_DIR}/state.env"
XRAY_CONFIG_FILE="/usr/local/etc/xray/config.json"
HYSTERIA_CONFIG_DIR="/etc/hysteria"
HYSTERIA_CONFIG_FILE="${HYSTERIA_CONFIG_DIR}/config.yaml"
HYSTERIA_CERT_FILE="${HYSTERIA_CONFIG_DIR}/server.crt"
HYSTERIA_KEY_FILE="${HYSTERIA_CONFIG_DIR}/server.key"
CLI_FILE="/usr/local/sbin/liuisray"
LEGACY_CLI_FILE="/usr/local/sbin/liuis-ray"

log() { printf '\033[1;32m[liuis-ray]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[liuis-ray] WARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[liuis-ray] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash install.sh [options]

Installs or upgrades:
  - VLESS + REALITY + RAW + Vision on TCP 443
  - Hysteria2 + Salamander on UDP 443
  - liuisray interactive management menu

Options:
  --port PORT                 VLESS REALITY TCP port (default: 443)
  --hy2-port PORT             Hysteria2 UDP port (default: 443)
  --server-name DOMAIN        REALITY SNI and target host
  --target-port PORT          REALITY target port (default: 443)
  --address HOST              Public IPv4 or domain placed in client links
  --name NAME                 ASCII node name (default: liuis-ray)
  --no-bbr                    Do not enable fq + BBR
  --force                     Back up and replace unmanaged configs
  -h, --help                  Show this help

Running this installer again upgrades an existing managed installation while
preserving its client credentials.
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

detect_public_ipv4() {
  local endpoint candidate
  for endpoint in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"; do
    candidate="$(curl -4fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

secure_state_file() {
  local owner mode
  [[ -f "$STATE_FILE" ]] || return 1
  owner="$(stat -c '%u' "$STATE_FILE")"
  mode="$(stat -c '%a' "$STATE_FILE")"
  [[ "$owner" == "0" ]] || die "Refusing to source state not owned by root: ${STATE_FILE}"
  (( (8#$mode & 0022) == 0 )) || die "Refusing to source writable state: ${STATE_FILE}"
}

while (( "$#" )); do
  case "$1" in
    --port)
      [[ $# -ge 2 ]] || die "--port requires a value"
      XRAY_PORT="$2"; XRAY_PORT_SET=1; shift 2
      ;;
    --hy2-port)
      [[ $# -ge 2 ]] || die "--hy2-port requires a value"
      HYSTERIA_PORT="$2"; HYSTERIA_PORT_SET=1; shift 2
      ;;
    --server-name)
      [[ $# -ge 2 ]] || die "--server-name requires a value"
      REALITY_SERVER_NAME="$2"; SERVER_NAME_SET=1; shift 2
      ;;
    --target-port)
      [[ $# -ge 2 ]] || die "--target-port requires a value"
      REALITY_TARGET_PORT="$2"; TARGET_PORT_SET=1; shift 2
      ;;
    --address)
      [[ $# -ge 2 ]] || die "--address requires a value"
      PUBLIC_ADDRESS="$2"; ADDRESS_SET=1; shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      NODE_NAME="$2"; NAME_SET=1; shift 2
      ;;
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

REQUESTED_XRAY_PORT="$XRAY_PORT"
REQUESTED_HYSTERIA_PORT="$HYSTERIA_PORT"
REQUESTED_SERVER_NAME="$REALITY_SERVER_NAME"
REQUESTED_TARGET_PORT="$REALITY_TARGET_PORT"
REQUESTED_ADDRESS="$PUBLIC_ADDRESS"
REQUESTED_NODE_NAME="$NODE_NAME"

MANAGED_UPGRADE=0
if secure_state_file; then
  MANAGED_UPGRADE=1
  # This file is created root-owned and non-writable by group/other.
  # shellcheck disable=SC1090
  source "$STATE_FILE"

  [[ "$XRAY_PORT_SET" -eq 0 ]] || XRAY_PORT="$REQUESTED_XRAY_PORT"
  [[ "$HYSTERIA_PORT_SET" -eq 0 ]] || HYSTERIA_PORT="$REQUESTED_HYSTERIA_PORT"
  [[ "$SERVER_NAME_SET" -eq 0 ]] || REALITY_SERVER_NAME="$REQUESTED_SERVER_NAME"
  [[ "$TARGET_PORT_SET" -eq 0 ]] || REALITY_TARGET_PORT="$REQUESTED_TARGET_PORT"
  [[ "$ADDRESS_SET" -eq 0 ]] || PUBLIC_ADDRESS="$REQUESTED_ADDRESS"
  [[ "$NAME_SET" -eq 0 ]] || NODE_NAME="$REQUESTED_NODE_NAME"

  XRAY_INSTALL_COMMIT="$PINNED_XRAY_INSTALL_COMMIT"
  XRAY_INSTALL_SHA256="$PINNED_XRAY_INSTALL_SHA256"
  XRAY_INSTALL_URL="https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_COMMIT}/install-release.sh"
  HYSTERIA_VERSION="$PINNED_HYSTERIA_VERSION"
  HYSTERIA_RELEASE_TAG="app%2Fv${HYSTERIA_VERSION}"
  HYSTERIA_PORT="${HYSTERIA_PORT:-443}"
  HYSTERIA_SNI="${HYSTERIA_SNI:-www.cloudflare.com}"
  log "Existing managed installation detected; upgrading in place."
fi

if [[ "$MANAGED_UPGRADE" -eq 1 ]] &&
  (( XRAY_PORT_SET == 1 || SERVER_NAME_SET == 1 || TARGET_PORT_SET == 1 )); then
  die "Changing an existing Xray port/REALITY target during upgrade is not supported. Re-run without those options."
fi

is_port "$XRAY_PORT" || die "Invalid Xray port: $XRAY_PORT"
is_port "$HYSTERIA_PORT" || die "Invalid Hysteria2 port: $HYSTERIA_PORT"
is_port "$REALITY_TARGET_PORT" || die "Invalid target port: $REALITY_TARGET_PORT"
is_domain "$REALITY_SERVER_NAME" || die "Invalid REALITY server name: $REALITY_SERVER_NAME"
is_domain "$HYSTERIA_SNI" || die "Invalid Hysteria2 SNI: $HYSTERIA_SNI"
[[ "$NODE_NAME" =~ ^[A-Za-z0-9._-]{1,48}$ ]] || die "Node name may contain only A-Z, a-z, 0-9, dot, underscore and hyphen."
if [[ -n "$PUBLIC_ADDRESS" ]]; then
  is_ipv4 "$PUBLIC_ADDRESS" || is_domain "$PUBLIC_ADDRESS" || die "--address must be an IPv4 address or domain."
fi

if [[ "$MANAGED_UPGRADE" -eq 0 && -s "$XRAY_CONFIG_FILE" && "$FORCE" -ne 1 ]]; then
  die "An unmanaged Xray config exists at ${XRAY_CONFIG_FILE}. Review it, then re-run with --force."
fi
if [[ "$MANAGED_UPGRADE" -eq 0 && -s "$HYSTERIA_CONFIG_FILE" && "$FORCE" -ne 1 ]]; then
  die "An unmanaged Hysteria config exists at ${HYSTERIA_CONFIG_FILE}. Review it, then re-run with --force."
fi

export DEBIAN_FRONTEND=noninteractive
log "Installing required packages..."
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssl qrencode

if [[ -z "$PUBLIC_ADDRESS" ]]; then
  log "Detecting the VPS public IPv4 address..."
  PUBLIC_ADDRESS="$(detect_public_ipv4 || true)"
  is_ipv4 "$PUBLIC_ADDRESS" || die "Could not detect a public IPv4 address. Use --address."
  log "Detected public IPv4: ${PUBLIC_ADDRESS}"
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

install -d -m 700 "$STATE_DIR"

if [[ "$MANAGED_UPGRADE" -eq 0 ]]; then
  UUID="$(/usr/local/bin/xray uuid)"
  KEY_OUTPUT="$(/usr/local/bin/xray x25519)"
  PRIVATE_KEY="$(awk -F': ' '/^PrivateKey:/ {print $2; exit}' <<<"$KEY_OUTPUT")"
  PUBLIC_KEY="$(awk -F': ' '/^(Password|PublicKey)( \(PublicKey\))?:/ {print $2; exit}' <<<"$KEY_OUTPUT")"
  if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY="$(sed -n '2{s/^[^:]*:[[:space:]]*//;p;}' <<<"$KEY_OUTPUT")"
  fi
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "Could not parse the X25519 key pair generated by Xray."
  SHORT_ID="$(openssl rand -hex 8)"

  if [[ -s "$XRAY_CONFIG_FILE" ]]; then
    cp -a "$XRAY_CONFIG_FILE" "${XRAY_CONFIG_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  fi

  XRAY_CONFIG_TMP="${TMP_DIR}/xray-config.json"
  cat >"$XRAY_CONFIG_TMP" <<EOF
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
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_SERVER_NAME}:${REALITY_TARGET_PORT}",
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

  /usr/local/bin/xray run -test -config "$XRAY_CONFIG_TMP"
  install -d -m 750 /usr/local/etc/xray
  XRAY_USER="$(systemctl show xray.service -p User --value 2>/dev/null || true)"
  XRAY_USER="${XRAY_USER:-nobody}"
  XRAY_GROUP="$(id -gn "$XRAY_USER" 2>/dev/null || true)"
  XRAY_GROUP="${XRAY_GROUP:-nogroup}"
  install -o root -g "$XRAY_GROUP" -m 640 "$XRAY_CONFIG_TMP" "$XRAY_CONFIG_FILE"
else
  [[ -s "$XRAY_CONFIG_FILE" ]] || die "Managed state exists but Xray config is missing: ${XRAY_CONFIG_FILE}"
  [[ -n "${UUID:-}" && -n "${PUBLIC_KEY:-}" && -n "${SHORT_ID:-}" ]] || die "Existing state is missing Xray client credentials."

  cp -a "$XRAY_CONFIG_FILE" "${XRAY_CONFIG_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  sed -i \
    -e 's/"network"[[:space:]]*:[[:space:]]*"tcp"/"network": "raw"/g' \
    -e 's/"dest"[[:space:]]*:/"target":/g' \
    "$XRAY_CONFIG_FILE"
  /usr/local/bin/xray run -test -config "$XRAY_CONFIG_FILE"
fi

case "$(uname -m)" in
  x86_64|amd64)
    HYSTERIA_ARCH="amd64"
    HYSTERIA_SHA256="86fef8e2f1b2bf41318ac96724eee6c3b449e4e510022cc89658b63a6713922a"
    ;;
  aarch64|arm64)
    HYSTERIA_ARCH="arm64"
    HYSTERIA_SHA256="9ec8f49f4ea554b1cac04e6f3690cea76ff835082e943e54196d7f323fcfba71"
    ;;
  *)
    die "Hysteria2 is supported by this installer only on amd64 and arm64."
    ;;
esac
HYSTERIA_URL="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_RELEASE_TAG}/hysteria-linux-${HYSTERIA_ARCH}"

log "Downloading pinned Hysteria2 v${HYSTERIA_VERSION}..."
curl -fL --retry 3 --connect-timeout 15 "$HYSTERIA_URL" -o "${TMP_DIR}/hysteria"
printf '%s  %s\n' "$HYSTERIA_SHA256" "${TMP_DIR}/hysteria" | sha256sum -c -
install -o root -g root -m 755 "${TMP_DIR}/hysteria" /usr/local/bin/hysteria

if ! getent group hysteria >/dev/null; then
  groupadd --system hysteria
fi
if ! id hysteria >/dev/null 2>&1; then
  useradd --system --gid hysteria --home-dir /var/lib/hysteria \
    --create-home --shell /usr/sbin/nologin hysteria
fi

install -d -o root -g hysteria -m 750 "$HYSTERIA_CONFIG_DIR"

if [[ "$MANAGED_UPGRADE" -eq 0 || -z "${HYSTERIA_AUTH:-}" || -z "${HYSTERIA_OBFS_PASSWORD:-}" ]]; then
  HYSTERIA_AUTH="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=[:space:]')"
  HYSTERIA_OBFS_PASSWORD="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=[:space:]')"
fi

if [[ ! -s "$HYSTERIA_CERT_FILE" || ! -s "$HYSTERIA_KEY_FILE" ]]; then
  log "Generating a self-signed Hysteria2 certificate with SHA-256 pinning..."
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -subj "/CN=${HYSTERIA_SNI}" \
    -addext "subjectAltName=DNS:${HYSTERIA_SNI}" \
    -keyout "$HYSTERIA_KEY_FILE" \
    -out "$HYSTERIA_CERT_FILE" >/dev/null 2>&1
fi

chown root:hysteria "$HYSTERIA_CERT_FILE" "$HYSTERIA_KEY_FILE"
chmod 640 "$HYSTERIA_CERT_FILE" "$HYSTERIA_KEY_FILE"
HYSTERIA_CERT_PIN="$(openssl x509 -noout -fingerprint -sha256 -in "$HYSTERIA_CERT_FILE" |
  awk -F= '{print $2}' | tr -d ':' | tr '[:upper:]' '[:lower:]')"
[[ "$HYSTERIA_CERT_PIN" =~ ^[0-9a-f]{64}$ ]] || die "Could not calculate Hysteria2 certificate fingerprint."

if [[ -s "$HYSTERIA_CONFIG_FILE" ]]; then
  cp -a "$HYSTERIA_CONFIG_FILE" "${HYSTERIA_CONFIG_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi

HYSTERIA_CONFIG_TMP="${TMP_DIR}/hysteria-config.yaml"
cat >"$HYSTERIA_CONFIG_TMP" <<EOF
listen: :${HYSTERIA_PORT}

tls:
  cert: ${HYSTERIA_CERT_FILE}
  key: ${HYSTERIA_KEY_FILE}
  sniGuard: disable

auth:
  type: password
  password: ${HYSTERIA_AUTH}

obfs:
  type: salamander
  salamander:
    password: ${HYSTERIA_OBFS_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com/
    rewriteHost: true
EOF
install -o root -g hysteria -m 640 "$HYSTERIA_CONFIG_TMP" "$HYSTERIA_CONFIG_FILE"

cat >/etc/systemd/system/hysteria-server.service <<'EOF'
[Unit]
Description=liuis-ray Hysteria2 Server
Documentation=https://hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hysteria
Group=hysteria
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF

save_state() {
  {
    printf 'PROJECT_VERSION=%q\n' "$INSTALLER_VERSION"
    printf 'XRAY_INSTALL_COMMIT=%q\n' "$XRAY_INSTALL_COMMIT"
    printf 'XRAY_INSTALL_SHA256=%q\n' "$XRAY_INSTALL_SHA256"
    printf 'XRAY_INSTALL_URL=%q\n' "$XRAY_INSTALL_URL"
    printf 'HYSTERIA_VERSION=%q\n' "$HYSTERIA_VERSION"
    printf 'HYSTERIA_ARCH=%q\n' "$HYSTERIA_ARCH"
    printf 'HYSTERIA_SHA256=%q\n' "$HYSTERIA_SHA256"
    printf 'HYSTERIA_URL=%q\n' "$HYSTERIA_URL"
    printf 'XRAY_PORT=%q\n' "$XRAY_PORT"
    printf 'HYSTERIA_PORT=%q\n' "$HYSTERIA_PORT"
    printf 'REALITY_SERVER_NAME=%q\n' "$REALITY_SERVER_NAME"
    printf 'REALITY_TARGET_PORT=%q\n' "$REALITY_TARGET_PORT"
    printf 'HYSTERIA_SNI=%q\n' "$HYSTERIA_SNI"
    printf 'PUBLIC_ADDRESS=%q\n' "$PUBLIC_ADDRESS"
    printf 'NODE_NAME=%q\n' "$NODE_NAME"
    printf 'UUID=%q\n' "$UUID"
    printf 'PUBLIC_KEY=%q\n' "$PUBLIC_KEY"
    printf 'SHORT_ID=%q\n' "$SHORT_ID"
    printf 'HYSTERIA_AUTH=%q\n' "$HYSTERIA_AUTH"
    printf 'HYSTERIA_OBFS_PASSWORD=%q\n' "$HYSTERIA_OBFS_PASSWORD"
    printf 'HYSTERIA_CERT_PIN=%q\n' "$HYSTERIA_CERT_PIN"
  } >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
  chown root:root "$STATE_FILE"
}
save_state

cat >"$CLI_FILE" <<'CLI_EOF'
#!/usr/bin/env bash
set -Euo pipefail
umask 077

STATE_FILE="/etc/liuis-ray/state.env"
XRAY_CONFIG_FILE="/usr/local/etc/xray/config.json"

green='\033[1;32m'
yellow='\033[1;33m'
red='\033[1;31m'
cyan='\033[1;36m'
reset='\033[0m'

log() { printf "${green}[liuis-ray]${reset} %s\n" "$*"; }
warn() { printf "${yellow}[liuis-ray] WARN:${reset} %s\n" "$*" >&2; }
die() { printf "${red}[liuis-ray] ERROR:${reset} %s\n" "$*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

load_state() {
  local owner mode
  [[ -r "$STATE_FILE" ]] || die "State file not found: $STATE_FILE"
  owner="$(stat -c '%u' "$STATE_FILE")"
  mode="$(stat -c '%a' "$STATE_FILE")"
  [[ "$owner" == "0" ]] || die "State file is not owned by root."
  (( (8#$mode & 0022) == 0 )) || die "State file must not be group/other writable."
  # This file is created root-owned and non-writable by group/other.
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

build_vless_uri() {
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s-vless' \
    "$UUID" "$PUBLIC_ADDRESS" "$XRAY_PORT" "$REALITY_SERVER_NAME" "$PUBLIC_KEY" "$SHORT_ID" "$NODE_NAME"
}

build_hysteria_uri() {
  printf 'hysteria2://%s@%s:%s/?insecure=1&obfs=salamander&obfs-password=%s&pinSHA256=%s&sni=%s#%s-hy2' \
    "$HYSTERIA_AUTH" "$PUBLIC_ADDRESS" "$HYSTERIA_PORT" "$HYSTERIA_OBFS_PASSWORD" \
    "$HYSTERIA_CERT_PIN" "$HYSTERIA_SNI" "$NODE_NAME"
}

show_config() {
  load_state
  cat <<EOF

VLESS + REALITY（TCP ${XRAY_PORT}）
$(build_vless_uri)

Hysteria2 + Salamander（UDP ${HYSTERIA_PORT}）
$(build_hysteria_uri)

云平台防火墙必须放行：
  TCP ${XRAY_PORT}
  UDP ${HYSTERIA_PORT}
EOF
}

show_qr() {
  load_state
  command -v qrencode >/dev/null || die "qrencode is not installed."
  case "${1:-all}" in
    vless)
      printf '\nVLESS + REALITY\n'
      qrencode -t ANSIUTF8 "$(build_vless_uri)"
      ;;
    hy2|hysteria2)
      printf '\nHysteria2\n'
      qrencode -t ANSIUTF8 "$(build_hysteria_uri)"
      ;;
    all)
      show_qr vless
      show_qr hy2
      ;;
    *) die "Use: liuisray qr [vless|hy2|all]" ;;
  esac
}

service_state() {
  local unit="$1" label="$2" state
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  if [[ "$state" == "active" ]]; then
    printf '  %-16s %b%s%b\n' "$label" "$green" "$state" "$reset"
  else
    printf '  %-16s %b%s%b\n' "$label" "$red" "${state:-unknown}" "$reset"
  fi
}

show_status() {
  load_state
  printf '\n服务状态\n'
  service_state xray.service "Xray"
  service_state hysteria-server.service "Hysteria2"
  printf '\n监听端口\n'
  ss -lntup 2>/dev/null |
    awk -v xp=":${XRAY_PORT}" -v hp=":${HYSTERIA_PORT}" '
      NR == 1 || ($1 == "tcp" && index($5, xp)) || ($1 == "udp" && index($5, hp))
    ' || true
  printf '\nBBR\n'
  printf '  qdisc=%s congestion=%s\n' \
    "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)" \
    "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
}

enable_bbr() {
  modprobe tcp_bbr 2>/dev/null || true
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    warn "This kernel does not expose BBR. Upgrade the VPS kernel and try again."
    return 1
  fi
  cat >/etc/sysctl.d/99-liuis-ray-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null
  [[ "$(sysctl -n net.core.default_qdisc)" == "fq" ]] || {
    warn "Failed to activate fq."
    return 1
  }
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] || {
    warn "Failed to activate BBR."
    return 1
  }
  log "fq + BBR is active for TCP traffic."
}

restart_services() {
  local target="${1:-all}"
  case "$target" in
    xray)
      /usr/local/bin/xray run -test -config "$XRAY_CONFIG_FILE" || return 1
      systemctl restart xray
      ;;
    hy2|hysteria2)
      systemctl restart hysteria-server
      ;;
    all)
      /usr/local/bin/xray run -test -config "$XRAY_CONFIG_FILE" || return 1
      systemctl restart xray hysteria-server
      ;;
    *) warn "Use: liuisray restart [xray|hy2|all]"; return 1 ;;
  esac
  sleep 1
  show_status
}

show_logs() {
  case "${1:-all}" in
    xray) journalctl --no-pager -n 100 -u xray ;;
    hy2|hysteria2) journalctl --no-pager -n 100 -u hysteria-server ;;
    all) journalctl --no-pager -n 100 -u xray -u hysteria-server ;;
    *) warn "Use: liuisray logs [xray|hy2|all]"; return 1 ;;
  esac
}

download_verified() {
  local url="$1" sha256="$2" output="$3"
  curl -fL --retry 3 --connect-timeout 15 "$url" -o "$output" || return 1
  printf '%s  %s\n' "$sha256" "$output" | sha256sum -c -
}

update_cores() {
  load_state
  local tmp_dir
  tmp_dir="$(mktemp -d)"

  log "Updating Xray through the pinned official installer..."
  if ! download_verified "$XRAY_INSTALL_URL" "$XRAY_INSTALL_SHA256" "${tmp_dir}/xray-install.sh" ||
    ! bash "${tmp_dir}/xray-install.sh" install ||
    ! /usr/local/bin/xray run -test -config "$XRAY_CONFIG_FILE"; then
    rm -rf -- "$tmp_dir"
    return 1
  fi

  log "Reinstalling pinned Hysteria2 v${HYSTERIA_VERSION}..."
  if ! download_verified "$HYSTERIA_URL" "$HYSTERIA_SHA256" "${tmp_dir}/hysteria"; then
    rm -rf -- "$tmp_dir"
    return 1
  fi
  install -o root -g root -m 755 "${tmp_dir}/hysteria" /usr/local/bin/hysteria

  systemctl restart xray hysteria-server
  rm -rf -- "$tmp_dir"
  sleep 1
  show_status
}

pause_menu() {
  [[ -t 0 ]] || return 0
  printf '\n按 Enter 返回菜单...'
  read -r _
}

draw_menu() {
  load_state
  [[ -t 1 ]] && clear
  printf "${cyan}"
  cat <<'EOF'
╭──────────────────────────────────────╮
│          liuis-ray 管理面板          │
╰──────────────────────────────────────╯
EOF
  printf "${reset}"
  service_state xray.service "Xray"
  service_state hysteria-server.service "Hysteria2"
  cat <<'EOF'

  1) 查看全部连接链接
  2) 显示 VLESS 二维码
  3) 显示 Hysteria2 二维码
  4) 查看服务和端口状态
  5) 重启全部服务
  6) 查看 Xray 日志
  7) 查看 Hysteria2 日志
  8) 启用并检查 fq + BBR
  9) 更新代理核心
  0) 退出
EOF
}

menu() {
  [[ -t 0 ]] || die "Interactive menu requires a terminal. Use 'liuisray help'."
  while true; do
    draw_menu
    printf '\n请选择 [0-9]: '
    read -r choice
    case "$choice" in
      1) show_config; pause_menu ;;
      2) show_qr vless; pause_menu ;;
      3) show_qr hy2; pause_menu ;;
      4) show_status; pause_menu ;;
      5) restart_services all; pause_menu ;;
      6) show_logs xray; pause_menu ;;
      7) show_logs hy2; pause_menu ;;
      8) enable_bbr; pause_menu ;;
      9) update_cores; pause_menu ;;
      0) exit 0 ;;
      *) warn "无效选项：${choice}"; sleep 1 ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Usage: liuisray [COMMAND]

No command opens the interactive management menu.

Commands:
  show                         Show both share URIs
  qr [vless|hy2|all]           Show terminal QR codes
  status                       Show services, ports and BBR
  logs [xray|hy2|all]          Show recent logs
  restart [xray|hy2|all]       Validate and restart services
  update                       Update using pinned upstream installers
  bbr                          Enable and verify fq + BBR
  menu                         Open the interactive menu
EOF
}

case "${1:-menu}" in
  menu) menu ;;
  show) show_config ;;
  qr) show_qr "${2:-all}" ;;
  status) show_status ;;
  logs) show_logs "${2:-all}" ;;
  restart) restart_services "${2:-all}" ;;
  update) update_cores ;;
  bbr) enable_bbr ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
CLI_EOF
chmod 755 "$CLI_FILE"
chown root:root "$CLI_FILE"
ln -sfn "$CLI_FILE" "$LEGACY_CLI_FILE"

install -d -m 755 /etc/systemd/system/xray.service.d
cat >/etc/systemd/system/xray.service.d/20-liuis-ray-hardening.conf <<'EOF'
[Service]
UMask=0077
Restart=on-failure
RestartSec=3s
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
/usr/local/bin/xray run -test -config "$XRAY_CONFIG_FILE"
systemctl enable xray hysteria-server
systemctl restart xray hysteria-server
sleep 1

for service in xray hysteria-server; do
  if ! systemctl --quiet is-active "$service"; then
    journalctl --no-pager -n 80 -u "$service" >&2
    die "${service} failed to start."
  fi
done

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  log "UFW is active; opening TCP ${XRAY_PORT} and UDP ${HYSTERIA_PORT}."
  ufw allow "${XRAY_PORT}/tcp"
  ufw allow "${HYSTERIA_PORT}/udp"
else
  warn "No active UFW detected. Open TCP ${XRAY_PORT} and UDP ${HYSTERIA_PORT} in the VPS provider firewall."
fi

if [[ "$ENABLE_BBR" -eq 1 ]]; then
  if ! "$CLI_FILE" bbr; then
    warn "The proxies are installed, but BBR could not be enabled on this kernel."
  fi
fi

printf '\n'
log "Installation/upgrade completed."
"$CLI_FILE" show
printf '\n管理面板：\n  sudo liuisray\n'

#!/usr/bin/env bash
# Validate the actual installer template with a supplied official Xray binary.
# Optional --smoke performs a local client/server handshake on high ports.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
CORE_BINARY="$(realpath -- "${1:?Usage: bash tests/core-config.sh /path/to/xray [--smoke]}")"
SMOKE="${2:-}"
PROJECT_DIR="$PWD"
TEST_DIR="$(mktemp -d "${PROJECT_DIR}/.core-test.XXXXXX")"
server_pid=""; client_pid=""; http_pid=""
cleanup() {
  [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
  [[ -z "$client_pid" ]] || kill "$client_pid" 2>/dev/null || true
  [[ -z "$http_pid" ]] || kill "$http_pid" 2>/dev/null || true
  local resolved
  resolved="$(realpath -m -- "$TEST_DIR")"
  case "$resolved" in "$PROJECT_DIR"/.core-test.*) rm -rf -- "$resolved" ;; esac
}
trap cleanup EXIT
source <(sed '/^while (( "\$#" )); do/,$d' install.sh)
MANAGED_UPGRADE=0
TMP_DIR="$TEST_DIR"
XRAY_CONFIG_FILE="$TEST_DIR/config.json"
XRAY_GROUP=root
XRAY_PORT=28443
REALITY_SERVER_NAME="${SMOKE_TARGET:-$REALITY_SERVER_NAME}"
PUBLIC_ADDRESS=127.0.0.1
NODE_NAME=smoke
run_core() { "$CORE_BINARY" "$@"; }
install() {
  local -a args=()
  while (($#)); do
    case "$1" in -o|-g|-m) shift 2 ;; *) args+=("$1"); shift ;; esac
  done
  if [[ "${args[0]}" == -d ]]; then mkdir -p -- "${args[@]:1}"; else cp -- "${args[@]}"; fi
}
chown() { return 0; }
sed -n '/^if \[\[ "\$MANAGED_UPGRADE" -eq 0 \]\]; then/,/^log "Installing pinned Hysteria2/p' install.sh |
  sed '$d; s|/usr/local/bin/xray|run_core|g' >"$TEST_DIR/render-config"
source "$TEST_DIR/render-config"
derived="$(run_core x25519 -i "$PRIVATE_KEY" | awk -F': ' '/^(Password|PublicKey)( \(PublicKey\))?:/ {print $2; exit}')"
[[ "$derived" == "$PUBLIC_KEY" ]] || { printf 'FAIL: generated key pair mismatch\n' >&2; exit 1; }
source <(sed -n '/^build_vless_uri() {/,/^}/p' install.sh)
uri="$(build_vless_uri)"
[[ "$uri" == *"pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp"* ]] || exit 1
printf 'PASS: actual core accepts generated config, derived public key matches share URI\n'
[[ "$SMOKE" == --smoke ]] || exit 0
# Modern cores block private destinations by default on server inbounds.
# Permit only this test's loopback endpoint; the deployed template stays intact.
sed -i 's/"protocol": "freedom"/"protocol": "freedom", "settings": {"finalRules": [{"action": "allow", "network": "tcp", "ip": ["127.0.0.1\/32"], "port": 28445}]}/' "$XRAY_CONFIG_FILE"
"${NODE_BINARY:-node}" -e 'require("http").createServer((req,res)=>{res.end("liuis-ray-smoke-ok")}).listen(28445,"127.0.0.1")' \
  >"$TEST_DIR/http.log" 2>&1 &
http_pid=$!
if [[ "${SMOKE_DEBUG:-0}" == 1 ]]; then
  sed -i -e 's/"loglevel": "warning"/"loglevel": "debug"/' \
    -e 's/"show": false/"show": true/' "$XRAY_CONFIG_FILE"
fi

cat >"$TEST_DIR/client.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": 28444, "protocol": "socks", "settings": {"auth": "noauth"}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "127.0.0.1", "port": ${XRAY_PORT}, "users": [{"id": "${UUID}", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
    "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {"serverName": "${REALITY_SERVER_NAME}", "fingerprint": "chrome", "publicKey": "${PUBLIC_KEY}", "shortId": "${SHORT_ID}"}}
  }]
}
EOF
if [[ "${SMOKE_DEBUG:-0}" == 1 ]]; then
  sed -i 's/"loglevel": "warning"/"loglevel": "debug"/' "$TEST_DIR/client.json"
fi
run_core run -test -config "$TEST_DIR/client.json"
"$CORE_BINARY" run -config "$XRAY_CONFIG_FILE" >"$TEST_DIR/server.log" 2>&1 &
server_pid=$!
"$CORE_BINARY" run -config "$TEST_DIR/client.json" >"$TEST_DIR/client.log" 2>&1 &
client_pid=$!
sleep 2
if ! curl -fsS --proxy socks5h://127.0.0.1:28444 --noproxy "" \
  --connect-timeout 20 --max-time 35 http://127.0.0.1:28445/ -o "$TEST_DIR/response"; then
  cat "$TEST_DIR/server.log" "$TEST_DIR/client.log" "$TEST_DIR/http.log" >&2
  exit 1
fi
grep -q '^liuis-ray-smoke-ok$' "$TEST_DIR/response"
printf 'PASS: local VLESS/REALITY handshake and end-to-end HTTP payload\n'

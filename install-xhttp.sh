#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CONFIG_DIR=/etc/liuis-ray-xhttp
BIN_DIR=/usr/local/lib/liuis-ray-xhttp
UNIT_FILE=/etc/systemd/system/liuis-ray-xhttp.service
CLI_FILE=/usr/local/sbin/liuisray-xhttp
SERVICE=liuis-ray-xhttp.service
ACCOUNT=liuis-ray-xhttp
SCRIPT_FILE="$(realpath -- "${BASH_SOURCE[0]}")"

die() { printf '[liuisray-xhttp] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[liuisray-xhttp] %s\n' "$*"; }

validate_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }

choose_port() {
  python3 - "$1" <<'PY'
import socket,sys
with socket.socket() as s:
    s.bind(('0.0.0.0',int(sys.argv[1])))
    print(s.getsockname()[1])
PY
}

release_metadata() {
  python3 - "$1" "$2" <<'PY'
import json,re,sys
release=json.load(open(sys.argv[1]))
tag=release['tag_name']
assert not release.get('draft') and not release.get('prerelease'), 'Expected official release'
assert re.fullmatch(r'v[0-9]+(?:\.[0-9]+)+',tag), 'Invalid release tag'
asset=next(a for a in release['assets'] if a['name']==sys.argv[2])
digest=asset.get('digest','')
assert re.fullmatch(r'sha256:[0-9a-f]{64}',digest), 'Official SHA-256 is missing'
url=asset['browser_download_url']
assert url=='https://github.com/XTLS/Xray-core/releases/download/'+tag+'/'+sys.argv[2], 'Unexpected asset URL'
print(tag); print(url); print(digest[7:])
PY
}

render_config() {
  python3 - "$@" <<'PY'
import json,re,sys,ipaddress,uuid
old,out,config,port,address,sni,version,newuuid,private,public,sid=sys.argv[1:]
state=json.load(open(old)) if old!='-' else dict(uuid=newuuid,private_key=private,public_key=public,short_id=sid,path='/'+str(uuid.uuid4())+'/',sni=sni or 'www.cloudflare.com')
if sni: state['sni']=sni
address=address or state.get('address','')
try: ipaddress.ip_address(address)
except ValueError:
    assert re.fullmatch(r'(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}',address), 'Invalid public address'
state.update(address=address,port=int(port),version=version)
assert 1<=state['port']<=65535
uuid.UUID(state['uuid'])
assert all(re.fullmatch(r'[A-Za-z0-9_-]{43}',state[k]) for k in ['private_key','public_key'])
assert re.fullmatch(r'[0-9a-f]{16}',state['short_id'])
assert re.fullmatch(r'/[A-Za-z0-9/-]+/',state['path'])
assert re.fullmatch(r'[A-Za-z0-9.-]+',state['sni'])
stream=dict(network='xhttp',security='reality',xhttpSettings=dict(path=state['path'],mode='auto'),realitySettings=dict(show=False,target=state['sni']+':443',serverNames=[state['sni']],privateKey=state['private_key'],shortIds=[state['short_id']]))
cfg=dict(log=dict(loglevel='warning'),inbounds=[dict(tag='vless-xhttp-reality',listen='0.0.0.0',port=state['port'],protocol='vless',settings=dict(clients=[dict(id=state['uuid'])],decryption='none'),streamSettings=stream)],outbounds=[dict(protocol='freedom',tag='direct')])
for name,data in [(out,state),(config,cfg)]:
    with open(name,'w') as f: json.dump(data,f,indent=2); f.write('\n')
PY
}

show_link() {
  [[ -r "$CONFIG_DIR/state.json" ]] || die 'XHTTP is not installed.'
  python3 - "$CONFIG_DIR/state.json" <<'PY'
import json,sys,urllib.parse
s=json.load(open(sys.argv[1]))
q=urllib.parse.urlencode(dict(encryption='none',security='reality',sni=s['sni'],fp='chrome',pbk=s['public_key'],sid=s['short_id'],type='xhttp',path=s['path'],mode='auto'))
host=s['address']; host='['+host+']' if ':' in host else host
print('Xray '+s['version']+' | TCP '+str(s['port'])+' | XHTTP + REALITY')
print('vless://'+s['uuid']+'@'+host+':'+str(s['port'])+'?'+q+'#liuis-ray-xhttp')
PY
}

install_service() {
  local port='' random=0 address='' sni='' temp existing=- old_port='' asset
  while (($#)); do
    case "$1" in
      --port) [[ $# -ge 2 ]] || die 'Missing --port value'; validate_port "$2" || die 'Port must be 1-65535'; port="$2"; shift 2 ;;
      --random-port) random=1; shift ;;
      --address) [[ $# -ge 2 ]] || die 'Missing --address value'; address="$2"; shift 2 ;;
      --server-name) [[ $# -ge 2 ]] || die 'Missing --server-name value'; sni="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$port" || "$random" == 0 ]] || die 'Choose --port or --random-port'
  [[ "$(uname -s)" == Linux && -d /run/systemd/system ]] || die 'Linux with systemd is required.'
  for path in "$CONFIG_DIR" "$BIN_DIR" "$UNIT_FILE" "$CLI_FILE" \
      "$CONFIG_DIR/config.json" "$CONFIG_DIR/state.json" "$BIN_DIR/xray"; do
    [[ ! -L "$path" ]] || die "Refusing redirected path: $path"
  done
  local dep
  for dep in curl python3 unzip openssl; do
    if ! command -v "$dep" >/dev/null; then
      command -v apt-get >/dev/null || die 'Install curl, python3, unzip and openssl first.'
      apt-get update
      apt-get install -y --no-install-recommends ca-certificates curl python3 unzip openssl
      break
    fi
  done
  if [[ -f "$CONFIG_DIR/state.json" ]]; then
    existing="$CONFIG_DIR/state.json"
    old_port="$(python3 - "$existing" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['port'])
PY
)"
    validate_port "$old_port" || die 'Invalid saved port'
  elif [[ -e "$BIN_DIR/xray" || -e "$UNIT_FILE" || -e "$CONFIG_DIR/config.json" ]]; then
    die 'Unmanaged XHTTP files found; no files were changed.'
  fi
  if [[ "$random" == 1 || ( -z "$port" && -z "$old_port" ) ]]; then
    port="$(choose_port 0)"
  elif [[ -z "$port" ]]; then
    port="$old_port"
  fi
  if [[ "$port" != "$old_port" ]]; then
    choose_port "$port" >/dev/null || die "TCP port $port is occupied."
  fi
  if [[ -z "$address" && "$existing" == - ]]; then
    address="$(curl -4fsS --connect-timeout 10 --max-time 20 https://api.ipify.org)"
  fi
  temp="$(mktemp -d)"
  XHTTP_TEMP_DIR="$temp"
  trap 'rm -rf -- "$XHTTP_TEMP_DIR"' EXIT
  case "$(uname -m)" in
    x86_64|amd64) asset=Xray-linux-64.zip ;;
    aarch64|arm64) asset=Xray-linux-arm64-v8a.zip ;;
    *) die 'Only amd64 and arm64 are supported.' ;;
  esac
  curl -fLsS --retry 3 --connect-timeout 15 --max-time 90 https://api.github.com/repos/XTLS/Xray-core/releases/latest -o "$temp/release.json"
  release_metadata "$temp/release.json" "$asset" >"$temp/release.txt"
  local -a release
  mapfile -t release <"$temp/release.txt"
  log "Downloading latest official Xray ${release[0]} for the separate XHTTP service."
  curl -fLsS --retry 3 --connect-timeout 15 --max-time 300 "${release[1]}" -o "$temp/xray.zip"
  printf '%s  %s\n' "${release[2]}" "$temp/xray.zip" | sha256sum -c -
  unzip -qo "$temp/xray.zip" xray -d "$temp"
  chmod 755 "$temp/xray"
  "$temp/xray" version | grep -F "Xray ${release[0]#v} " >/dev/null || die 'Unexpected core version'
  local uuid='' private='' public='' sid=''
  if [[ "$existing" == - ]]; then
    uuid="$("$temp/xray" uuid)"
    "$temp/xray" x25519 >"$temp/keys"
    private="$(awk -F': ' '/^PrivateKey:/ {print $2}' "$temp/keys")"
    public="$(awk -F': ' '/^(Password|PublicKey)( \(PublicKey\))?:/ {print $2; exit}' "$temp/keys")"
    sid="$(openssl rand -hex 8)"
  fi
  render_config "$existing" "$temp/state.json" "$temp/config.json" "$port" "$address" "$sni" "${release[0]}" "$uuid" "$private" "$public" "$sid"
  "$temp/xray" run -test -config "$temp/config.json"
  cat >"$temp/service" <<EOF
[Unit]
Description=liuis-ray optional VLESS XHTTP REALITY
After=network-online.target
Wants=network-online.target
[Service]
User=$ACCOUNT
Group=$ACCOUNT
ExecStart=$BIN_DIR/xray run -config $CONFIG_DIR/config.json
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
  local backup was_active=0 was_enabled=0 file key
  backup="$(mktemp -d /var/backups/liuis-ray-xhttp.XXXXXXXX)"
  local -a files=("$BIN_DIR/xray" "$CONFIG_DIR/config.json" "$CONFIG_DIR/state.json" "$UNIT_FILE" "$CLI_FILE")
  local -a keys=(xray config state unit cli)
  for key in "${!files[@]}"; do
    file="${files[$key]}"
    [[ ! -f "$file" ]] || cp -p -- "$file" "$backup/${keys[$key]}"
  done
  systemctl is-active --quiet "$SERVICE" && was_active=1
  systemctl is-enabled --quiet "$SERVICE" && was_enabled=1
  rollback() {
    trap - ERR
    set +e
    systemctl stop "$SERVICE"
    for key in "${!files[@]}"; do
      if [[ -f "$backup/${keys[$key]}" ]]; then cp -p -- "$backup/${keys[$key]}" "${files[$key]}"; else rm -f -- "${files[$key]}"; fi
    done
    [[ "$was_enabled" == 1 ]] || systemctl disable "$SERVICE"
    systemctl daemon-reload
    [[ "$was_active" == 0 ]] || systemctl start "$SERVICE"
    printf '[liuisray-xhttp] Installation failed; optional service restored. Backup: %s\n' "$backup" >&2
    exit 1
  }
  trap rollback ERR
  if ! getent passwd "$ACCOUNT" >/dev/null; then
    useradd --system --user-group --no-create-home --shell /usr/sbin/nologin "$ACCOUNT"
  fi
  install -d -m 750 -o root -g "$ACCOUNT" "$CONFIG_DIR"
  install -d -m 755 -o root -g root "$BIN_DIR"
  systemctl stop "$SERVICE" 2>/dev/null || true
  install -m 755 -o root -g root "$temp/xray" "$BIN_DIR/xray"
  install -m 640 -o root -g "$ACCOUNT" "$temp/config.json" "$CONFIG_DIR/config.json"
  install -m 600 -o root -g root "$temp/state.json" "$CONFIG_DIR/state.json"
  install -m 644 -o root -g root "$temp/service" "$UNIT_FILE"
  if [[ "$SCRIPT_FILE" != "$CLI_FILE" ]]; then
    install -m 755 -o root -g root "$SCRIPT_FILE" "$CLI_FILE"
  fi
  systemctl daemon-reload
  systemctl enable "$SERVICE"
  systemctl restart "$SERVICE"
  local restarts_before restarts_after
  restarts_before="$(systemctl show "$SERVICE" -p NRestarts --value)"
  sleep 3
  systemctl is-active --quiet "$SERVICE"
  restarts_after="$(systemctl show "$SERVICE" -p NRestarts --value)"
  [[ "$restarts_before" == "$restarts_after" ]]
  trap - ERR
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow "${port}/tcp" || log "Open TCP $port manually in UFW."
  fi
  log "Installed independently. Open TCP $port in your cloud firewall. Backup: $backup"
  show_link
}

main() {
  [[ "${1:-}" != -h && "${1:-}" != --help && "${1:-}" != help ]] || {
    printf '%s\n' 'Usage: liuisray-xhttp [install [--port PORT | --random-port] [--address IP_OR_HOST] [--server-name SNI] | show | status | logs | restart]'
    return
  }
  [[ "$(id -u)" == 0 ]] || die 'Run as root.'
  case "${1:-install}" in
    install) [[ $# == 0 ]] || shift; install_service "$@" ;;
    --*) install_service "$@" ;;
    show) show_link ;;
    status) systemctl status "$SERVICE" --no-pager ;;
    logs) journalctl -u "$SERVICE" -n 80 --no-pager ;;
    restart) "$BIN_DIR/xray" run -test -config "$CONFIG_DIR/config.json"; systemctl restart "$SERVICE" ;;
    *) die 'Unknown command; use --help.' ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi

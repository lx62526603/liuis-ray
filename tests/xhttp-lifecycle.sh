#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
[[ -d /run/systemd/system ]] || { echo 'SKIP: Linux/systemd platform check unavailable'; exit 0; }
source ./install-xhttp.sh
TEST_DIR="$(mktemp -d "$PWD/.xhttp-lifecycle.XXXXXX")"
cleanup() {
  local resolved="$(realpath -m -- "$TEST_DIR")"
  case "$resolved" in "$PWD"/.xhttp-lifecycle.*) rm -rf -- "$resolved" ;; esac
}
trap cleanup EXIT
CONFIG_DIR="$TEST_DIR/config"; BIN_DIR="$TEST_DIR/bin"
UNIT_FILE="$TEST_DIR/unit"; CLI_FILE="$TEST_DIR/cli"
mkdir -p "$TEST_DIR/fixture"
printf 'original-vless-and-hy2\n' >"$TEST_DIR/original-services"
python3 - "$TEST_DIR/fixture" <<'PY'
import pathlib,sys,zipfile,hashlib,json
p=pathlib.Path(sys.argv[1])
script='''#!/usr/bin/env bash
case "$1" in
version) echo 'Xray 26.11.9 test' ;;
uuid) echo '12345678-1234-1234-1234-123456789abc' ;;
x25519) echo 'PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; echo 'Password (PublicKey): BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' ;;
run) exit 0 ;;
*) exit 1 ;;
esac
'''
with zipfile.ZipFile(p/'core.zip','w') as z: z.writestr('xray',script)
h=hashlib.sha256((p/'core.zip').read_bytes()).hexdigest()
json.dump(dict(tag_name='v26.11.9',draft=False,prerelease=False,assets=[dict(name='Xray-linux-64.zip',digest='sha256:'+h,browser_download_url='https://github.com/XTLS/Xray-core/releases/download/v26.11.9/Xray-linux-64.zip')]),open(p/'release.json','w'))
PY
curl() {
  local output='' url='' arg
  while (($#)); do
    case "$1" in -o) output="$2"; shift 2 ;; https://*) url="$1"; shift ;; *) shift ;; esac
  done
  case "$url" in
    */releases/latest) cp "$TEST_DIR/fixture/release.json" "$output" ;;
    */Xray-linux-64.zip) cp "$TEST_DIR/fixture/core.zip" "$output" ;;
    *) echo 'Unexpected network request' >&2; return 1 ;;
  esac
}
apt-get() { die 'Unexpected dependency installation in isolated test'; }
unzip() {
  python3 - "$2" "${@: -1}" <<'PY'
import zipfile,sys,pathlib
with zipfile.ZipFile(sys.argv[1]) as z:
    pathlib.Path(sys.argv[2],'xray').write_bytes(z.read('xray'))
PY
}
openssl() { printf '0123456789abcdef\n'; }
getent() { return 0; }
useradd() { echo 'Unexpected user mutation' >&2; return 1; }
sleep() { :; }
ufw() { echo inactive; }
install() {
  local -a args=()
  while (($#)); do
    case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
  done
  command install "${args[@]}"
}
mktemp() {
  if [[ "${2:-}" == /var/backups/liuis-ray-xhttp.* ]]; then
    command mktemp -d "$TEST_DIR/backup.XXXXXXXX"
  else command mktemp "$@"; fi
}
systemctl() {
  printf '%s\n' "$*" >>"$TEST_DIR/calls"
  case "$1" in
    is-active) [[ -e "$TEST_DIR/active" ]] ;;
    is-enabled) [[ -e "$TEST_DIR/enabled" ]] ;;
    stop) rm -f "$TEST_DIR/active" ;;
    enable) touch "$TEST_DIR/enabled" ;;
    disable) rm -f "$TEST_DIR/enabled" ;;
    restart) [[ "${FAIL_RESTART:-0}" == 0 ]] || return 1; touch "$TEST_DIR/active" ;;
    start) touch "$TEST_DIR/active" ;;
    show) echo 0 ;;
    daemon-reload) : ;;
    *) return 1 ;;
  esac
}
(install_service --address 203.0.113.10) >"$TEST_DIR/first.log"
cp "$CONFIG_DIR/state.json" "$TEST_DIR/first-state.json"
SCRIPT_FILE="$CLI_FILE"
(install_service --port 23456) >"$TEST_DIR/update.log"
python3 - "$CONFIG_DIR/state.json" "$TEST_DIR/first-state.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); t=json.load(open(sys.argv[2]))
assert s['port']==23456 and all(s[k]==t[k] for k in ['uuid','private_key','public_key','short_id','path'])
PY
before="$(sha256sum "$CONFIG_DIR/config.json" "$CONFIG_DIR/state.json" "$BIN_DIR/xray" "$UNIT_FILE" "$CLI_FILE")"
set +e
(set -e; FAIL_RESTART=1; install_service --port 23457) >"$TEST_DIR/failed.log" 2>&1
result=$?
set -e
[[ "$result" != 0 ]] || die 'Failed restart was ignored'
after="$(sha256sum "$CONFIG_DIR/config.json" "$CONFIG_DIR/state.json" "$BIN_DIR/xray" "$UNIT_FILE" "$CLI_FILE")"
[[ "$before" == "$after" && -f "$TEST_DIR/active" && -f "$TEST_DIR/enabled" ]]
grep -q 'original-vless-and-hy2' "$TEST_DIR/original-services"
! grep -Eq '(^| )(xray|hysteria-server)(\.service)?( |$)' "$TEST_DIR/calls"
printf 'PASS: isolated install, credential-preserving port update and failed-restart rollback\n'

#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
TEST_DIR="$(mktemp -d "$PWD/.show-status-test.XXXXXX")"
cleanup() {
  local resolved="$(realpath -m -- "$TEST_DIR")"
  case "$resolved" in "$PWD"/.show-status-test.*) rm -rf -- "$resolved" ;; esac
}
trap cleanup EXIT
for name in service_state read_xhttp_port show_xhttp_state show_status draw_menu; do
  source <(sed -n "/^${name}() {/,/^}/p" install.sh)
done
load_state() { :; }
sysctl() { echo test; }
systemctl() {
  [[ "$1" == is-active ]] || exit 99
  if [[ "$2" == liuis-ray-xhttp.service ]]; then echo "$XHTTP_TEST_STATUS"; else echo active; fi
}
ss() {
  printf 'Netid State Recv-Q Send-Q Local Peer\n'
  printf 'tcp LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'
  printf 'udp UNCONN 0 0 0.0.0.0:443 0.0.0.0:*\n'
  printf 'tcp LISTEN 0 128 0.0.0.0:4433 0.0.0.0:*\n'
  printf 'tcp LISTEN 0 128 [::]:32123 [::]:*\n'
}
green=''; red=''; reset=''; cyan=''
XRAY_PORT=443; HYSTERIA_PORT=443
XHTTP_STATE_FILE="$TEST_DIR/state.json"; XHTTP_CLI_FILE="$TEST_DIR/absent-cli"
XHTTP_TEST_STATUS=active
show_status >"$TEST_DIR/not-installed"
grep -q '未安装' "$TEST_DIR/not-installed"
! grep -q ':32123' "$TEST_DIR/not-installed"
! grep -q ':4433' "$TEST_DIR/not-installed"
printf '{"port":32123}\n' >"$XHTTP_STATE_FILE"
show_status >"$TEST_DIR/installed"
draw_menu >"$TEST_DIR/menu"
grep -q 'XHTTP + REALITY.*active' "$TEST_DIR/installed"
grep -q 'XHTTP TCP port: 32123' "$TEST_DIR/menu"
grep -q '\[::\]:32123' "$TEST_DIR/installed"
! grep -q ':4433' "$TEST_DIR/installed"
XHTTP_TEST_STATUS=inactive
show_status >"$TEST_DIR/stopped"
grep -q 'XHTTP + REALITY.*inactive' "$TEST_DIR/stopped"
printf 'PASS: menu/status show XHTTP active/inactive/uninstalled and exact listen port\n'

#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
TEST_DIR="$(mktemp -d "$PWD/.show-config-test.XXXXXX")"
cleanup() {
  local resolved="$(realpath -m -- "$TEST_DIR")"
  case "$resolved" in "$PWD"/.show-config-test.*) rm -rf -- "$resolved" ;; esac
}
trap cleanup EXIT
source <(sed -n '/^build_vless_uri() {/,/^}/p' install.sh)
source <(sed -n '/^build_hysteria_uri() {/,/^}/p' install.sh)
source <(sed -n '/^show_config() {/,/^}/p' install.sh)
load_state() { :; }
warn() { echo "$*" >&2; }
UUID=test-uuid; PUBLIC_ADDRESS=203.0.113.10; XRAY_PORT=443; REALITY_SERVER_NAME=www.bing.com
PUBLIC_KEY=test-public; SHORT_ID=test-short; NODE_NAME=test
HYSTERIA_AUTH=test-auth; HYSTERIA_PORT=443; HYSTERIA_OBFS_PASSWORD=test-obfs
HYSTERIA_CERT_PIN=test-pin; HYSTERIA_SNI=www.cloudflare.com
XHTTP_CLI_FILE="$TEST_DIR/xhttp"
show_config >"$TEST_DIR/before"
grep -q '^vless://.*type=tcp' "$TEST_DIR/before"
grep -q '^hysteria2://' "$TEST_DIR/before"
! grep -q '独立通道' "$TEST_DIR/before"
cat >"$XHTTP_CLI_FILE" <<'SH'
#!/usr/bin/env bash
[[ "$1" == show && $# == 1 ]] || exit 99
printf 'Xray test | TCP 32123 | XHTTP + REALITY\nvless://test@203.0.113.10:32123?type=xhttp#test\n'
SH
chmod +x "$XHTTP_CLI_FILE"
show_config >"$TEST_DIR/after"
python3 - "$TEST_DIR/before" "$TEST_DIR/after" <<'PY'
import pathlib,sys
before=pathlib.Path(sys.argv[1]).read_text(); after=pathlib.Path(sys.argv[2]).read_text()
assert after.startswith(before)
assert '独立通道' in after and 'TCP 32123' in after and '?type=xhttp' in after
assert after.count('type=tcp')==1 and after.count('hysteria2://')==1
PY
printf 'PASS: all-links view includes installed XHTTP without changing original links\n'

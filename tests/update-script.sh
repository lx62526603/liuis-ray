#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./update-script.sh
TEST_DIR="$(mktemp -d "$PWD/.update-script-test.XXXXXX")"
cleanup() {
  local resolved="$(realpath -m -- "$TEST_DIR")"
  case "$resolved" in "$PWD"/.update-script-test.*) rm -rf -- "$resolved" ;; esac
}
trap cleanup EXIT
id() { echo 0; }
systemctl() { echo 'Unexpected service mutation' >&2; exit 99; }
apt-get() { echo 'Unexpected package mutation' >&2; exit 99; }
export -f id systemctl apt-get
render_manager install.sh "$TEST_DIR/generated"
bash "$TEST_DIR/generated" help | grep -q update-script
grep -q '13) 更新管理脚本' "$TEST_DIR/generated"
printf 'PASS: actual generated menu/help without installer side effects\n'
CLI_FILE="$TEST_DIR/liuisray"
printf 'old-manager\n' >"$CLI_FILE"
printf 'keep-config-credentials-and-cores\n' >"$TEST_DIR/unrelated"
curl() { cp install.sh "${@: -1}"; }
(update_manager) >"$TEST_DIR/update.log"
cmp "$CLI_FILE" "$TEST_DIR/generated"
grep -q old-manager "$CLI_FILE".backup.*
grep -q keep-config-credentials-and-cores "$TEST_DIR/unrelated"
printf 'PASS: script-only update and backup preserve unrelated files\n'
before="$(sha256sum "$CLI_FILE")"
curl() { printf '#!/bin/bash\nif broken\n' >"${@: -1}"; }
set +e
(set -e; update_manager) >"$TEST_DIR/failed.log" 2>&1
result=$?
set -e
[[ "$result" != 0 && "$before" == "$(sha256sum "$CLI_FILE")" ]]
printf 'PASS: invalid download leaves installed manager unchanged\n'
